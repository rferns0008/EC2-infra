# ==========================================
# 1. PROVIDER & REGION
# ==========================================
provider "aws" {
  region = "ap-south-1" 
}

# ==========================================
# 2. NETWORK INFRASTRUCTURE (MANAGEMENT)
# ==========================================
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
  tags = { Name = "Mgmt-Private-Route-Table" }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt.id
}

# ==========================================
# 3. SECURITY & ENDPOINTS
# ==========================================
resource "aws_security_group" "eic_sg" {
  name   = "eic-endpoint-sg"
  vpc_id = aws_vpc.devops_vpc.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ec2_instance_connect_endpoint" "eic_endpoint" {
  subnet_id          = aws_subnet.private.id
  security_group_ids = [aws_security_group.eic_sg.id]
  tags               = { Name = "VPC-Tunnel-Endpoint" }
}

resource "aws_security_group" "internal_sg" {
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
    security_groups = [aws_security_group.eic_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# 4. IAM ROLE (MINIMAL ACCESS)
# ==========================================
resource "aws_iam_role" "jenkins_mgmt_role" {
  name = "jenkins-management-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# No S3, EKS, or ECR policies attached here to maintain total isolation.

resource "aws_iam_instance_profile" "jenkins_mgmt_profile" {
  name = "jenkins-management-profile"
  role = aws_iam_role.jenkins_mgmt_role.name
}

# ==========================================
# 5. EC2 INSTANCES
# ==========================================
locals {
  devops_setup = <<-EOF
                 #!/bin/bash
                 sudo apt update
                 sudo apt install -y docker.io unzip
                 sudo usermod -aG docker ubuntu
                 sudo chmod 666 /var/run/docker.sock
                 EOF
}

resource "aws_instance" "jenkins_server" {
  ami                    = "ami-09d76355bd4eecccf" 
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.internal_sg.id]
  key_name               = "promethius-grafana-keypair"
  iam_instance_profile   = aws_iam_instance_profile.jenkins_mgmt_profile.name
  user_data              = local.devops_setup
  tags                   = { Name = "Jenkins-Server-Private" }
}

resource "aws_instance" "jenkins_agents" {
  count                  = 2
  ami                    = "ami-05afe695674ad97eb"
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.internal_sg.id]
  key_name               = "promethius-grafana-keypair"
  iam_instance_profile   = aws_iam_instance_profile.jenkins_mgmt_profile.name
  user_data              = local.devops_setup
  tags                   = { Name = "Jenkins-Agent-0${count.index + 1}-Private" }
}

resource "aws_instance" "monitoring_stack" {
  ami                    = "ami-0c842822bfbc83b45"
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.internal_sg.id]
  key_name               = "promethius-grafana-keypair"
  iam_instance_profile   = aws_iam_instance_profile.jenkins_mgmt_profile.name
  user_data              = local.devops_setup
  tags                   = { Name = "Monitoring-Stack-Private" }
 
}
 
# ==========================================
# 6. VPC PEERING (MANAGEMENT AS REQUESTER)
# ==========================================
# Find the Chatbot VPC
data "aws_vpc" "chatbot_vpc" {
  filter {
    name   = "tag:Name"
    values = ["chatbot-production-vpc"]
  }
}

# Create the Peering Connection
resource "aws_vpc_peering_connection" "mgmt_to_chatbot" {
  vpc_id      = aws_vpc.devops_vpc.id
  peer_vpc_id = data.aws_vpc.chatbot_vpc.id
  auto_accept = true # Auto-accept works because both VPCs are in the same account/region
  
  tags = { Name = "Mgmt-to-Chatbot-Peering" }
}

# Add Route: Mgmt Private -> Chatbot VPC
resource "aws_route" "mgmt_private_to_chatbot" {
  route_table_id            = aws_route_table.private_rt.id
  destination_cidr_block    = data.aws_vpc.chatbot_vpc.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.mgmt_to_chatbot.id
}

# Add Route: Mgmt Public -> Chatbot VPC
resource "aws_route" "mgmt_public_to_chatbot" {
  route_table_id            = aws_route_table.public_rt.id
  destination_cidr_block    = data.aws_vpc.chatbot_vpc.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.mgmt_to_chatbot.id
}

# ==========================================
# 7. CHATBOT VPC RETURN ROUTING
# ==========================================

# Find the specific private route table in the Chatbot VPC
data "aws_route_table" "chatbot_private_rt" {
  vpc_id = data.aws_vpc.chatbot_vpc.id
  filter {
    name   = "tag:Name"
    values = ["chatbot-production-vpc-private"]
  }
}

# Inject the return route back to the Management VPC
resource "aws_route" "chatbot_to_mgmt_return" {
  route_table_id            = data.aws_route_table.chatbot_private_rt.id
  destination_cidr_block    = aws_vpc.devops_vpc.cidr_block # 10.0.0.0/16
  vpc_peering_connection_id = aws_vpc_peering_connection.mgmt_to_chatbot.id
}