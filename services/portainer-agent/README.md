# Portainer Agent

Connects this server to the Portainer server on the NAS (port 9001). No `.env` needed.

**Rule:** use Portainer here only to look, read logs and restart. Changes made in Portainer bypass git and are lost on the next deploy.

The agent's version should match the Portainer server's version on the NAS. Upgrade both together.
