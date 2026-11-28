# Portainer Agent

Connects this server to the Portainer server on the NAS (port 9001). No `.env` needed.

**Rule:** use Portainer here only to look, read logs and restart. Changes made in Portainer bypass git and are lost on the next deploy.

The agent's version matches the Portainer server's on the NAS. The server isn't in git (it can't manage its own stack), so Renovate only sees the agent; `renovate.json5` keeps it below 3.x because the server has no 3.x.

## Upgrading
Server first, then the agent to the same version:
1. NAS over SSH: `sudo docker ps` for the container name, `sudo docker inspect <name>` to note its ports, mounts and restart policy, then copy its data folder.
2. `sudo docker pull portainer/portainer-ce:<version>`, `sudo docker stop <name> && sudo docker rm <name>`, and `sudo docker run -d` with the same name, ports, mounts and restart policy on the new image. Data stays in the mount.
3. Check `http://192.168.10.7:9000/api/system/status` shows the new version, then merge the agent's Renovate PR (or set the tag in `compose.yaml`). The environment shows as up in Portainer.
