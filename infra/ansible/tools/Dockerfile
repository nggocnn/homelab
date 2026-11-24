# The Ansible controller as a container, so a fresh laptop needs only Docker.
# Same versions the README pins for the apt install: ansible 13.1.0 (ansible-core 2.20.x, 2.20.11 when built).
#   docker build -t homelab-ansible --build-arg UID=$(id -u) --build-arg GID=$(id -g) infra/ansible/tools
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

# A user with the host's uid/gid (ansible.sh passes them), so files written to the repo and
# ~/.ssh stay the host user's. A passwd entry is required: ssh looks up the running uid and
# refuses with "No user exists for uid 1000" without one, and takes ~/.ssh from its home field.
ARG UID=1000
ARG GID=1000
RUN groupadd -o -g "$GID" ansible \
 && useradd -o -u "$UID" -g "$GID" -d /home/ansible -m -s /bin/sh ansible
ENV HOME=/home/ansible \
    ANSIBLE_FORCE_COLOR=1
WORKDIR /work/infra/ansible
