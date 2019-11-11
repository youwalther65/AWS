#!/bin/bash
vpccidr=10.1.0.0/16
subnetcidr=10.1.1.0/24
instancetype="t3.micro"
userdat="user-data.txt"
aminame="AWSLinux2HttpEnabledJUWAMI"
amidesc="AWS Linux 2 HTTP Enabled JUWi AMI"
AWS_DEFAULT_REGION=us-west-1
export AWS_DEFAULT_REGION

echo "Creating VPC with CID $vpccidr"
vpcid=$(aws ec2 create-vpc --cidr-block $vpccidr --query 'Vpc.VpcId' --output text)
echo "VPC ID: $vpcid"

echo "Creating subnet in VPC $vpcid with CID $subnetcidr"
subnetid=$(aws ec2 create-subnet --vpc-id $vpcid --cidr-block $subnetcidr --query 'Subnet.SubnetId' --output text)
echo "Subnet ID: $subnetid"

echo "Creating internet gateway"
igatewayid=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
echo "Internet gateway ID: $igatewayid"

echo "Attaching internet gateway $igatewayid to VPC $vpcid"
aws ec2 attach-internet-gateway --vpc-id $vpcid --internet-gateway-id $igatewayid

echo "Creating route table in VPC $vpcid"
routetableid=$(aws ec2 create-route-table --vpc-id $vpcid --query 'RouteTable.RouteTableId' --output text)
echo "Route table ID: $routetableid"

echo "Creating default route to internet gateway $igatewayid in route table $routetableid"
aws ec2 create-route --route-table-id $routetableid --destination-cidr-block 0.0.0.0/0 --gateway-id $igatewayid > /dev/null
echo "Describe route table $routetableid"
aws ec2 describe-route-tables --route-table-id $routetableid

echo "Associate route table $routetableid with subnet $subnetid"
aws ec2 associate-route-table  --subnet-id $subnetid --route-table-id $routetableid > /dev/null

echo "Set attribute \"map-public-ip-on-launch\" for subnet $subnetid"
aws ec2 modify-subnet-attribute --subnet-id $subnetid --map-public-ip-on-launch

echo "Create security group with SSH and HTTP access from 0.0.0.0/0"
secgroupid=$(aws ec2 create-security-group --group-name SSHHttpAccess --description "Security group for SSH and HTTP access" --vpc-id  $vpcid --query 'GroupId' --output text)
echo "Security group ID: $secgroupid"
aws ec2 authorize-security-group-ingress --group-id $secgroupid --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $secgroupid --protocol tcp --port 80 --cidr 0.0.0.0/0
echo "Describe security group ID $secgroupid"
aws ec2 describe-security-groups --group-id $secgroupid

echo "Creating user data input file $userdat"
cat <<EOF > $userdat
#!/bin/bash
yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd
usermod -a -G apache ec2-user
chown -R ec2-user:apache /var/www
chmod 2775 /var/www
find /var/www -type d -exec chmod 2775 {} \;
find /var/www -type f -exec chmod 0664 {} \;
mv /etc/httpd/conf.d/welcome.conf /etc/httpd/conf.d/welcome.conf_backup
systemctl restart httpd
curl https://gist.githubusercontent.com/youwalther65/e8788a80f03eac2e81d40421e4f21f7f/raw/380339de4bb0c05220a5e878e14ad38a47cf1081/index.html -o /var/www/html/index.html
curl https://aws.amazon.com/favicon.ico -o /var/www/html/favicon.ico -o /var/www/html/favicon.ico
EOF

echo "Determing latest AWS Linux 2 image in region"
amiid=$(aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 --query 'Parameters[].Value' --output text)
echo "AMI ID: $amiid"

echo "Creating EC2 instance from AMI $amiid"
instanceid=$(aws ec2 run-instances --image-id $amiid --count 1 --instance-type $instancetype \
--subnet-id $subnetid --security-group-ids $secgroupid \
--user-data file://${userdat} --query 'Instances[].InstanceId' --output text)
echo "Instance ID: $instanceid"

echo "Wating 2 min for instance $instanceid to become available"
sleep 120
pubip=$(aws ec2 describe-instances --instance-id $instanceid --query 'Reservations[].Instances[].PublicIpAddress' --output text)
echo "Public IP address: $pubip"
echo "Fetching web page from instance $instanceid"
curl $pubip

echo "Stopping instance $instanceid to get create clean snapshot and AMI"
aws ec2 stop-instances --instance-id $instanceid
sleep 120
echo "Taking snapshot from stopped instance $instanceid"
snapid=$(aws ec2 create-image --instance-id $instanceid --name $aminame --description "$amidesc" --query 'ImageId' --output text)
echo "AMI ID: $snapid"
sleep 120
echo "Making AMI §snapid public"
aws ec2 modify-image-attribute --image-id $snapid --launch-permission "Add=[{Group=all}]"
aws ec2 describe-images --image-id $snapid
