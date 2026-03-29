# ==========================================
# 1. PROVIDER & NETWORK
# ==========================================
provider "aws" {
  region = "ap-south-1" 
}

data "aws_region" "current" {}

resource "aws_vpc" "devops_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "Management-VPC" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.devops_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-south-1a"
  tags              = { Name = "Mgmt-Public-Subnet" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.devops_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-south-1a"
  tags              = { Name = "Mgmt-Private-Subnet" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.devops_vpc.id
}

resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags   = { Name = "NAT-Gateway-EIP" }
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.igw]
  tags          = { Name = "Mgmt-NAT-Gateway" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.devops_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.devops_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt.id
}

# ==========================================
# 2. SECURITY GROUPS (MATCHING STATE)
# ==========================================
resource "aws_security_group" "eic_sg_new" {
  name   = "eic-endpoint-sg"
  vpc_id = aws_vpc.devops_vpc.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "internal_sg_new" {
  name        = "internal-devops-sg"
  description = "Allows all internal traffic between DevOps tools"
  vpc_id      = aws_vpc.devops_vpc.id

  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eic_sg_new.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# 3. ENDPOINTS, LOCKS & STORAGE
# ==========================================
resource "aws_ec2_instance_connect_endpoint" "eic_endpoint" {
  subnet_id          = aws_subnet.private.id
  security_group_ids = [aws_security_group.eic_sg_new.id]
  tags               = { Name = "VPC-Tunnel-Endpoint" }
}

resource "aws_vpc_endpoint" "s3_endpoint" {
  vpc_id            = aws_vpc.devops_vpc.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway" 
  route_table_ids   = [aws_route_table.private_rt.id]
  tags              = { Name = "Mgmt-S3-VPC-Endpoint" }
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "terraform-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

resource "aws_s3_bucket" "monitoring_assets" {
  bucket_prefix = "devops-monitoring-assets-"
  force_destroy = true
  tags          = { Name = "Monitoring-Assets-Bucket" }
}

resource "aws_s3_object" "flask_dashboard" {
  bucket = aws_s3_bucket.monitoring_assets.id
  key    = "dashboards/flask_dashboard.json"
  source = "./9688_rev1.json"
  etag   = filemd5("./9688_rev1.json")
}

# ==========================================
# 4. IAM ROLES (LEAST PRIVILEGE)
# ==========================================
resource "aws_iam_role" "jenkins_role" {
  name               = "jenkins-management-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "jenkins-management-profile"
  role = aws_iam_role.jenkins_role.name
}

resource "aws_iam_role" "monitoring_role" {
  name               = "monitoring-management-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_instance_profile" "monitoring_profile" {
  name = "monitoring-management-profile"
  role = aws_iam_role.monitoring_role.name
}

resource "aws_iam_role_policy" "monitoring_bootstrap" {
  name = "monitoring-bootstrap"
  role = aws_iam_role.monitoring_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = ["${aws_s3_bucket.monitoring_assets.arn}/*"] },
      { Effect = "Allow", Action = ["ec2:DescribeInstances"], Resource = ["*"] }
    ]
  })
}

# ==========================================
# 5. EC2 INSTANCES & USER DATA
# ==========================================
locals {
  devops_setup = <<-EOF
                 #!/bin/bash
                 sudo apt update
                 sudo apt install -y docker.io unzip
                 sudo usermod -aG docker ubuntu
                 sudo chmod 666 /var/run/docker.sock
                 EOF

  grafana_setup = <<-EOF
    #!/bin/bash
    sudo apt update
    sudo apt install -y docker.io unzip awscli jq
    EKS_IP=$(aws ec2 describe-instances --region ${data.aws_region.current.name} --filters "Name=tag:eks:cluster-name,Values=secure-eks-testing" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].PrivateIpAddress" --output text)
    if [ -z "$EKS_IP" ] || [ "$EKS_IP" == "None" ]; then EKS_IP="127.0.0.1"; fi
    sudo mkdir -p /etc/grafana/provisioning/datasources/
    sudo mkdir -p /etc/grafana/provisioning/dashboards/
    sudo mkdir -p /var/lib/grafana/dashboards/
    cat << 'YAML' | sudo tee /etc/grafana/provisioning/datasources/prometheus.yaml
    apiVersion: 1
    datasources:
      - name: Prometheus-EKS
        type: prometheus
        url: http://$${EKS_IP}:30271
        isDefault: true
    YAML
    cat << 'YAML' | sudo tee /etc/grafana/provisioning/dashboards/dashboards.yaml
    apiVersion: 1
    providers:
      - name: 'Chatbot-Dashboards'
        options:
          path: /var/lib/grafana/dashboards
    YAML
    aws s3 cp s3://${aws_s3_bucket.monitoring_assets.id}/dashboards/flask_dashboard.json /var/lib/grafana/dashboards/flask_dashboard.json
    sudo systemctl restart grafana-server
  EOF
}

resource "aws_instance" "jenkins_server" {
  ami                    = "ami-09d76355bd4eecccf" 
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.internal_sg_new.id]
  key_name               = "promethius-grafana-keypair"
  iam_instance_profile   = aws_iam_instance_profile.jenkins_profile.name
  user_data              = local.devops_setup
  tags                   = { Name = "Jenkins-Server-Private" }
}

resource "aws_instance" "jenkins_agents" {
  count                  = 2
  ami                    = "ami-05afe695674ad97eb"
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.internal_sg_new.id]
  key_name               = "promethius-grafana-keypair"
  iam_instance_profile   = aws_iam_instance_profile.jenkins_profile.name
  user_data              = local.devops_setup
  tags                   = { Name = "Jenkins-Agent-0${count.index + 1}-Private" }
}

resource "aws_instance" "monitoring_stack" {
  ami                    = "ami-0c842822bfbc83b45"
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.internal_sg_new.id]
  key_name               = "promethius-grafana-keypair"
  iam_instance_profile   = aws_iam_instance_profile.monitoring_profile.name
  user_data              = local.grafana_setup
  tags                   = { Name = "Monitoring-Stack-Private" }
}

# ==========================================
# 6. VPC PEERING
# ==========================================
data "aws_vpc" "chatbot_vpc" {
  filter {
    name   = "tag:Name"
    values = ["chatbot-production-vpc"]
  }
}

resource "aws_vpc_peering_connection" "mgmt_to_chatbot" {
  vpc_id      = aws_vpc.devops_vpc.id
  peer_vpc_id = data.aws_vpc.chatbot_vpc.id
  auto_accept = true 
  tags        = { Name = "Mgmt-to-Chatbot-Peering" }
}

resource "aws_route" "mgmt_private_to_chatbot" {
  route_table_id            = aws_route_table.private_rt.id
  destination_cidr_block    = data.aws_vpc.chatbot_vpc.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.mgmt_to_chatbot.id
}

resource "aws_route" "mgmt_public_to_chatbot" {
  route_table_id            = aws_route_table.public_rt.id
  destination_cidr_block    = data.aws_vpc.chatbot_vpc.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.mgmt_to_chatbot.id
}
