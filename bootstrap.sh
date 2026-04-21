#!/bin/bash

component=$1
environment=$2
dnf install ansible -y

REPO_URL=https://github.com/srinivaskaipu2705-alt/ansible-roboshop-roles-tf.git

# ... existing variable definitions ...
REPO_DIR="/opt/roboshop/ansible"
rm -rf $REPO_DIR
# 1. Ensure the directory exists
mkdir -p $REPO_DIR

# 2. Check if the directory is already a git repo or has files
if [ ! -d "$REPO_DIR/.git" ]; then
    echo "Cloning repository contents into $REPO_DIR..."
    # Cloning into an existing directory using '.' 
    git clone $REPO_URL $REPO_DIR
else
    echo "Repository already exists. Pulling latest changes."
    cd $REPO_DIR
    git pull origin main
fi

# 3. Run the Ansible playbook from the correct root
cd $REPO_DIR
ansible-playbook -e component=${component} -e env=${environment} main.yaml