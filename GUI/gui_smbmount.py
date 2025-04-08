import os
import re
import subprocess
import sys
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QLabel, QLineEdit,
                             QPushButton, QMessageBox, QComboBox, QListWidget, QInputDialog,
                             QAbstractItemView, QFormLayout, QGroupBox)
from PyQt5.QtCore import Qt
from getpass import getpass
from pathlib import Path


class SMBAuthDialog(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("SMB Authentication")
        self.setup_ui()

    def setup_ui(self):
        layout = QVBoxLayout()

        form_group = QGroupBox("Authentication")
        form_layout = QFormLayout()

        self.username_input = QLineEdit()
        self.password_input = QLineEdit()
        self.password_input.setEchoMode(QLineEdit.Password)

        form_layout.addRow("Username:", self.username_input)
        form_layout.addRow("Password:", self.password_input)
        form_group.setLayout(form_layout)

        self.ok_button = QPushButton("OK")
        self.ok_button.clicked.connect(self.accept)

        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.clicked.connect(self.reject)

        layout.addWidget(form_group)
        layout.addWidget(self.ok_button)
        layout.addWidget(self.cancel_button)

        self.setLayout(layout)

    def accept(self):
        if not self.username_input.text():
            QMessageBox.warning(self, "Warning", "Username cannot be empty!")
            return
        super().accept()

    def reject(self):
        super().reject()

    def get_credentials(self):
        return (self.username_input.text(), self.password_input.text())


class SMBMountGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("SMB Mount Tool")
        self.setGeometry(100, 100, 600, 400)
        self.credentials = None
        self.username = None
        self.password = None
        self.setup_ui()

    def setup_ui(self):
        central_widget = QWidget()
        self.setCentralWidget(central_widget)

        layout = QVBoxLayout()

        # Server connection group
        server_group = QGroupBox("Server Connection")
        server_layout = QFormLayout()

        self.host_input = QLineEdit()
        self.share_name_input = QLineEdit()

        server_layout.addRow("Server IP/Hostname:", self.host_input)
        server_layout.addRow("Mount folder name (optional):", self.share_name_input)
        server_group.setLayout(server_layout)

        # Authentication group
        auth_group = QGroupBox("Authentication")
        auth_layout = QVBoxLayout()

        self.auth_method = QComboBox()
        self.auth_method.addItem("Existing ~/.cifs", "existing")
        self.auth_method.addItem("New credentials file", "new")
        self.auth_method.addItem("Manual input", "manual")
        auth_layout.addWidget(self.auth_method)

        auth_group.setLayout(auth_layout)

        # Shares selection
        self.shares_list = QListWidget()
        self.shares_list.setSelectionMode(QAbstractItemView.MultiSelection)

        # Buttons
        self.connect_button = QPushButton("Connect")
        self.connect_button.clicked.connect(self.connect_to_server)

        self.mount_button = QPushButton("Mount Selected")
        self.mount_button.clicked.connect(self.mount_shares)
        self.mount_button.setEnabled(False)

        # Add widgets to main layout
        layout.addWidget(server_group)
        layout.addWidget(auth_group)
        layout.addWidget(QLabel("Available Shares:"))
        layout.addWidget(self.shares_list)
        layout.addWidget(self.connect_button)
        layout.addWidget(self.mount_button)

        central_widget.setLayout(layout)

    def get_safe_name(self, name):
        """Convert unsafe characters to underscores"""
        return re.sub(r'[^a-zA-Z0-9_-]', '_', name)

    def check_host(self, host):
        """Ping the host to check availability"""
        try:
            subprocess.run(["ping", "-c", "2", host],
                          check=True,
                          stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)
            return True
        except subprocess.CalledProcessError:
            return False

    def create_credentials_file(self, path):
        """Create a credentials file"""
        dialog = SMBAuthDialog()
        if dialog.exec_() == QDialog.Accepted:
            username, password = dialog.get_credentials()
            try:
                with open(path, 'w') as f:
                    f.write(f"username={username}\npassword={password}\n")
                os.chmod(path, 0o600)
                return True
            except IOError as e:
                QMessageBox.critical(self, "Error", f"Failed to create credentials file: {e}")
        return False

    def connect_to_server(self):
        """Connect to SMB server and list available shares"""
        host = self.host_input.text().strip()
        if not host:
            QMessageBox.warning(self, "Warning", "Please enter a server hostname or IP")
            return

        if not self.check_host(host):
            QMessageBox.critical(self, "Error", f"Host {host} is unreachable. Check your connection.")
            return

        # Handle authentication
        auth_method = self.auth_method.currentData()
        if auth_method == "existing":
            cred_path = str(Path.home() / ".cifs")
            if not os.path.exists(cred_path):
                reply = QMessageBox.question(
                    self,
                    "File not found",
                    "Credentials file not found. Create one?",
                    QMessageBox.Yes | QMessageBox.No
                )
                if reply == QMessageBox.Yes:
                    if not self.create_credentials_file(cred_path):
                        return
                else:
                    return
            self.credentials = cred_path
            self.username = None
            self.password = None
        elif auth_method == "new":
            mount_name = self.share_name_input.text().strip()
            if not mount_name:
                mount_name = self.get_safe_name(host)
            cred_path = str(Path.home() / f".{mount_name}-credentials")

            if os.path.exists(cred_path):
                reply = QMessageBox.question(
                    self,
                    "File exists",
                    "Credentials file exists. Overwrite?",
                    QMessageBox.Yes | QMessageBox.No
                )
                if reply == QMessageBox.No:
                    return

            if not self.create_credentials_file(cred_path):
                return

            self.credentials = cred_path
            self.username = None
            self.password = None
        else:  # manual
            dialog = SMBAuthDialog()
            if dialog.exec_() == QDialog.Accepted:
                self.username, self.password = dialog.get_credentials()
                self.credentials = None
            else:
                return

        # Get shares list
        try:
            if self.credentials:
                cmd = ["smbclient", "-A", self.credentials, "-L", f"//{host}", "-m", "SMB3"]
            else:
                cmd = ["smbclient", "-L", f"//{host}", "-m", "SMB3",
                      "-U", f"{self.username}%{self.password}"]

            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                raise subprocess.CalledProcessError(result.returncode, cmd, result.stderr)

            shares = []
            for line in result.stdout.splitlines():
                if "Disk" in line:
                    share = line.split()[0]
                    if share not in ["IPC$", "print$"]:  # Skip system shares
                        shares.append(share)

            if not shares:
                QMessageBox.warning(self, "Warning", "No shares available")
                return

            self.shares_list.clear()
            self.shares_list.addItems(shares)
            self.shares_list.addItem("+ Add hidden share")
            self.mount_button.setEnabled(True)

        except subprocess.CalledProcessError as e:
            QMessageBox.critical(self, "Error", f"Failed to list shares: {e.stderr}")

    def mount_shares(self):
        """Mount selected shares"""
        host = self.host_input.text().strip()
        if not host:
            QMessageBox.warning(self, "Warning", "No server specified")
            return

        selected_items = self.shares_list.selectedItems()
        if not selected_items:
            QMessageBox.warning(self, "Warning", "No shares selected")
            return

        mount_base = self.share_name_input.text().strip()
        if not mount_base:
            mount_base = self.get_safe_name(host)

        mount_dir = Path.home() / mount_base
        try:
            mount_dir.mkdir(exist_ok=True)
        except OSError as e:
            QMessageBox.critical(self, "Error", f"Failed to create mount directory: {e}")
            return

        # Prepare mount options
        if self.credentials:
            mount_options = f"credentials={self.credentials},uid={os.getuid()},gid={os.getgid()},file_mode=0660,dir_mode=0770"
        else:
            mount_options = f"username={self.username},password={self.password},uid={os.getuid()},gid={os.getgid()},file_mode=0660,dir_mode=0770"

        success_count = 0
        fail_count = 0
        report = "Mount results:\n\n"

        for item in selected_items:
            share = item.text()
            if share == "+ Add hidden share":
                share, ok = QInputDialog.getText(
                    self,
                    "Hidden Share",
                    "Enter hidden share name (e.g., share$):"
                )
                if not ok or not share:
                    continue

            safe_share = self.get_safe_name(share)
            share_mount_dir = mount_dir / safe_share
            try:
                share_mount_dir.mkdir(exist_ok=True)
            except OSError as e:
                report += f"❌ Error creating directory for {share}: {e}\n"
                fail_count += 1
                continue

            # Check if already mounted
            try:
                mount_check = subprocess.run(["mount"], capture_output=True, text=True)
                if f"//{host}/{share}" in mount_check.stdout:
                    report += f"⚠️ {share} already mounted at {share_mount_dir}\n"
                    continue
            except subprocess.CalledProcessError:
                pass

            # Try mounting with udisksctl first
            try:
                subprocess.run(
                    ["udisksctl", "mount", "-t", "cifs", "-b", f"//{host}/{share}",
                     "-o", mount_options],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                report += f"✅ Success: {share} → {share_mount_dir}\n"
                success_count += 1
                continue
            except subprocess.CalledProcessError:
                pass

            # Fall back to sudo mount.cifs
            try:
                subprocess.run(
                    ["sudo", "mount.cifs", f"//{host}/{share}", str(share_mount_dir),
                     "-o", mount_options],
                    check=True
                )
                report += f"✅ Success (sudo): {share} → {share_mount_dir}\n"
                success_count += 1
            except subprocess.CalledProcessError as e:
                report += f"❌ Failed to mount {share}: {e}\n"
                fail_count += 1

        report += f"\nSummary: {success_count} successful, {fail_count} failed"

        if fail_count == 0:
            QMessageBox.information(self, "Success", report)
        elif success_count == 0:
            QMessageBox.critical(self, "Error", report)
        else:
            QMessageBox.information(self, "Results", report)


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = SMBMountGUI()
    window.show()
    sys.exit(app.exec_())
