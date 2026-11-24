# AWS provider module — VPC + subnet + IGW + security group + key pair +
# EC2 instance with an Elastic IP. Mirrors the genesis-amazon role
# (ec2-security-group) and the ufw role on the host.

variable "name" {
  type    = string
  default = "streisand"
}
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
variable "ami" {
  type    = string
  default = ""
}
variable "ssh_public_key" { type = string }
variable "ssh_key_name" {
  type    = string
  default = "streisand"
}
variable "user_data" { type = string }

variable "tcp_ports" {
  type    = list(number)
  default = [22, 443, 636, 993, 4443, 8530, 8443, 9443]
}
variable "udp_ports" {
  type    = list(number)
  default = [443, 8757, 4443, 8530, 51820]
}

data "aws_ami" "ubuntu" {
  most_recent = true
  # Canonical publishes noble from 099720109477; 099720109473 (older
  # releases) kept for regions/accounts that still serve from it.
  owners = ["099720109473", "099720109477"]
  filter {
    name = "name"
    values = [
      "ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*",
      "ubuntu/images/hvm-ssd*/ubuntu-24.04-amd64-server-*",
    ]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami = var.ami != "" ? var.ami : data.aws_ami.ubuntu.id
}

resource "aws_vpc" "streisand" {
  cidr_block = "10.200.0.0/16"
  tags       = { Name = var.name }
}

resource "aws_subnet" "streisand" {
  vpc_id                  = aws_vpc.streisand.id
  cidr_block              = "10.200.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.region}a"
  tags                    = { Name = var.name }
}

resource "aws_internet_gateway" "streisand" {
  vpc_id = aws_vpc.streisand.id
  tags   = { Name = var.name }
}

resource "aws_route_table" "streisand" {
  vpc_id = aws_vpc.streisand.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.streisand.id
  }
  tags = { Name = var.name }
}

resource "aws_route_table_association" "streisand" {
  subnet_id      = aws_subnet.streisand.id
  route_table_id = aws_route_table.streisand.id
}

resource "aws_security_group" "streisand" {
  name   = "${var.name}-sg"
  vpc_id = aws_vpc.streisand.id

  dynamic "ingress" {
    for_each = var.tcp_ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
  dynamic "ingress" {
    for_each = var.udp_ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "udp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "streisand" {
  key_name   = var.ssh_key_name
  public_key = var.ssh_public_key
}

resource "aws_instance" "streisand" {
  ami                         = local.ami
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.streisand.id
  vpc_security_group_ids      = [aws_security_group.streisand.id]
  key_name                    = aws_key_pair.streisand.key_name
  user_data                   = var.user_data
  associate_public_ip_address = true

  tags = { Name = var.name }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eip" "streisand" {
  instance = aws_instance.streisand.id
  domain   = "vpc"
  tags     = { Name = var.name }
}

output "server_ip" {
  value       = aws_eip.streisand.public_ip
  description = "Elastic IP of the provisioned EC2 instance"
}
output "instance_id" {
  value = aws_instance.streisand.id
}