# The Ansible controller as a container, so a fresh laptop needs only Docker.
# Same versions the README pins for the apt install: ansible 13.1.0 (ansible-core 2.20.x, 2.20.11 when built).
#   docker build -t homelab-ansible infra/ansible/tools
#   infra/ansible/tools/ansible.sh ansible-playbook playbooks/00-host.yml --check --diff
FROM python:3.13-slim-trixie

# openssh-client: the ssh connection and ssh-keygen for signing; whois: mkpasswd for the
# password hashes; git: ansible-galaxy from git, and ansible-lint's project detection.
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssh-client whois git \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
      ansible==13.1.0 \
      paramiko==4.0.0 \
      ansible-lint==25.11.0

# The wrapper runs as the host user (uid/gid passed in), with HOME pointing here.
RUN install -d -m 0777 /home/ansible
ENV HOME=/home/ansible \
    ANSIBLE_FORCE_COLOR=1
WORKDIR /work/infra/ansible
