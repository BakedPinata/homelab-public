# Instructions For Mounting Network Folders on Boot
## Steps

1. Installation and Setup
First, install the necessary utilities and create a directory where the network drive will appear.

```bash
sudo apt-get install cifs-utils
sudo mkdir /media/networkdrive
sudo chown $USER:$USER /media/networkdrive
```

2. Create Credentials File
Create a hidden file to store your username and password securely.

```bash
nano ~/.smbcredentials
```

Add the following lines, replacing the placeholders with your actual credentials:

```
username=your_windows_username
password=your_windows_password
```

Set strict permissions so only you can read this file:

```bash
chmod 600 ~/.smbcredentials
```

3. Configure /etc/fstab
Open the fstab file to define the permanent mount.

```bash
sudo nano /etc/fstab
```

Add the following line at the end, replacing the server details and paths with your own. Ensure uid and gid match your local user ID (found via the id command).
```
//server_ip/share_name /media/networkdrive cifs credentials=/home/your_username/.smbcredentials,uid=1000,gid=1000,vers=3.0 0 0
```

4. Verify Mount
Test the configuration by mounting all drives defined in fstab without rebooting.

```bash
sudo mount -a
```

## Specific `/etc/fstab` Lines

```
//192.168.10.7/Docker /media/docker cifs credentials=/home/<user>/.smbcredentials,uid=1000,gid=1000,vers=3.0 0 0
//192.168.10.7/Downloads /media/Downloads cifs credentials=/home/<user>/.smbcredentials,uid=1000,gid=1000,vers=3.0 0 0
//192.168.10.7/Video /media/Video cifs credentials=/home/<user>/.smbcredentials,uid=1000,gid=1000,vers=3.0 0 0
//192.168.10.7/photos /media/Photos cifs credentials=/home/<user>/.smbcredentials,uid=1000,gid=1000,vers=3.0 0 0
```
