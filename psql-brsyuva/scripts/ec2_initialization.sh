#!/bin/bash

set -xe

#Update apt index and upgrade all packages
sudo apt update

#Remove package which checks daemons need to be restarted after library upgrades
sudo apt -y -qq remove needrestart

#Upgrade system packages to the latest version
sudo apt -qq dist-upgrade -y

#clean cache
sudo apt-get -qq clean -y

#Install PostgreSQL package from Ubuntu repo
sudo apt install -qq postgresql unzip -y

#Install Latest AWS cli package
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip

#check aws version installed
aws --version

#Reference: https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-policies-s3.html#iam-policy-ex3
export latest_s3_db=$(aws s3 ls s3://visualpathbackups/brsyuva/db/ --recursive | sort | tail -n-1 | awk '{print $4}' | awk -F'/' '{print $3}') || exit 1
aws s3 cp s3://visualpathbackups/brsyuva/db/${latest_s3_db} /tmp/initial_db_backup || exit 1

set +xe
#Pull DB secrets from SSM
export PSQL_DBNAME=$(aws --region=ap-south-1 ssm get-parameter --name "/brsyuva/db_name" --with-decryption --output text --query Parameter.Value)
export PGPASSWORD=$(aws --region=ap-south-1 ssm get-parameter --name "/brsyuva/db_password" --with-decryption --output text --query Parameter.Value)
#Reference: https://www.postgresql.org/docs/current/libpq-envars.html
#Reference: https://stackoverflow.com/questions/48226592/aws-ssm-get-parameter-rsa-key-output-to-file

#Set password for postgres user and grant privilages
sudo su - postgres bash -c "psql -c \"CREATE DATABASE ${PSQL_DBNAME};\""
sudo su - postgres bash -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE ${PSQL_DBNAME} TO postgres;\""
sudo su - postgres bash -c "psql -c \"ALTER DATABASE ${PSQL_DBNAME} OWNER TO postgres;\""
sudo su - postgres bash -c "psql -c \"ALTER USER postgres PASSWORD '${PGPASSWORD}';\""

#Initiate the backup restore
export PGPASSWORD=$(aws --region=ap-south-1 ssm get-parameter --name "/brsyuva/db_password" --with-decryption --output text --query Parameter.Value)
psql -h 127.0.0.1 -U postgres -d ${PSQL_DBNAME} < /tmp/initial_db_backup

# Install the CodeDeploy agent on Ubuntu Server
# Reference: https://docs.aws.amazon.com/codedeploy/latest/userguide/codedeploy-agent-operations-install-ubuntu.html
sudo apt update -qq
sudo apt install -qq -y ruby-full
sudo apt install -qq -y wget

wget https://aws-codedeploy-ap-south-1.s3.ap-south-1.amazonaws.com/latest/install
chmod +x ./install
sudo ./install auto > /tmp/codedeploy_agent_logfile

sudo systemctl enable codedeploy-agent
sudo systemctl start codedeploy-agent

# Update PostgreSQL database configuration files for remote access
sudo cp /etc/postgresql/14/main/postgresql.conf /etc/postgresql/14/main/postgresql-backup
sudo echo "listen_addresses = '0.0.0.0'" >> /etc/postgresql/14/main/postgresql.conf

sudo cp /etc/postgresql/14/main/pg_hba.conf /etc/postgresql/14/main/pg_hba-backup
sudo echo "host    ${PSQL_DBNAME}      postgres        0.0.0.0/0       scram-sha-256" >> /etc/postgresql/14/main/pg_hba.conf

# Restart PostgreSQL after changes
sudo systemctl restart postgresql.service
sudo systemctl enable postgresql.service

# Update script to set cronjob for daily DB backup
[ -d /backups ] || sudo mkdir /backups
sudo cat <<'EOF' >> /backups/psql_full_backup.sh
#!/bin/bash

set -xe

db_name="brsyubaprod"

# Perfrom full backup of BRSyuva database
echo "Initializing full DB backup of $db_name...."
set +xe

export PGPASSWORD=$(aws --region=ap-south-1 ssm get-parameter --name "/brsyuva/db_password" --with-decryption --output text --query Parameter.Value)
set -xe

pg_dump -h 127.0.0.1 -U postgres -d ${db_name} > /backups/full-backup-$(date +%F_%R).sql || echo "Backup failed..."

# Push latest backup to s3 bucket BRSyuva DB backups
echo "Delete old backups"
find /backups/ -mtime +3 -type f -iname "*.sql" -exec rm {} \;

echo "Initiated backup upload to s3 bucket...."
latest_backup=$(ls -lrt /backups/*.sql | tail -n-1 | awk '{print $9}')

aws s3 cp ${latest_backup} s3://visualpathbackups/brsyuva/db/
echo "Successfully uploaded....."

aws s3 sync --delete /backups/ s3://visualpathbackups/brsyuva/db/ --include "*.sql" --exclude "*.sh"
EOF

# Set execute permissions for the script and push to crontab under root user
sudo chmod +x /backups/psql_full_backup.sh
sudo -i
(crontab -l 2>/dev/null; echo "0 3 * * * bash /backups/psql_full_backup.sh") | crontab -