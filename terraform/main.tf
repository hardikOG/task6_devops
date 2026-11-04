terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
    local  = { source = "hashicorp/local", version = "~> 2.0" }
    random = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "shop" {
  key_name   = "shop-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/../ansible/id_ed25519"
  file_permission = "0600"
}

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "local_sensitive_file" "ansible_secrets" {
  filename = "${path.module}/../ansible/group_vars/web.yml"
  content  = "grafana_admin_password: ${random_password.grafana_admin.result}\n"
}

resource "aws_security_group" "shop" {
  name        = "shop-sg"
  description = "Store, Grafana and SSH"

  ingress {
    description = "Store, through nginx"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Grafana, behind its admin login"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    # Open because GitHub-hosted runners have no fixed IP. Login is by SSH key only.
    description = "SSH for Ansible"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "shop" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.shop.key_name
  vpc_security_group_ids = [aws_security_group.shop.id]
  tags                   = { Name = "ecommerce-shop" }

  root_block_device {
    volume_size = 16
    volume_type = "gp3"
  }
}

# Keeps the address stable when the instance stops and restarts, so the pipeline's target doesn't change.
resource "aws_eip" "shop" {
  instance = aws_instance.shop.id
  domain   = "vpc"
  tags     = { Name = "ecommerce-shop" }
}

resource "local_file" "inventory" {
  filename = "${path.module}/../ansible/inventory.ini"
  content  = <<-INI
    [web]
    ${aws_eip.shop.public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/shop-key
  INI
}

output "public_ip" {
  value = aws_eip.shop.public_ip
}

output "store_url" {
  value = "http://${aws_eip.shop.public_ip}"
}

output "grafana_url" {
  value = "http://${aws_eip.shop.public_ip}:3000"
}

output "grafana_admin_password" {
  value     = random_password.grafana_admin.result
  sensitive = true
}
