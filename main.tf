terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "ap-northeast-2"
  access_key = ""
  secret_key = ""
}

resource "tls_private_key" "rsa_4096" {
  algorithm = "RSA"
  rsa_bits = 4096
}

variable "key_name" {
  description = "pem file"
  type = string
  default = "awslearner_keypair_win"
}

resource "aws_key_pair" "key_pair" {
  key_name = var.key_name
  public_key = tls_private_key.rsa_4096.public_key_openssh
}

resource "local_file" "private_key" {
  content = tls_private_key.rsa_4096.private_key_pem
  filename = var.key_name 
}

# Create a VPC
resource "aws_vpc" "goormVPC" {
  cidr_block = "172.16.0.0/16"
}

# Create Subnet
resource "aws_subnet" "zone-a" {
  vpc_id = aws_vpc.goormVPC.id
  cidr_block = "172.16.1.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name = "zone-a"
  }
}

resource "aws_subnet" "zone-c" {
  vpc_id = aws_vpc.goormVPC.id
  cidr_block = "172.16.2.0/24"
  availability_zone = "ap-northeast-2c"

  tags = {
    Name = "zone-c"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.goormVPC.id

  tags = {
    Name = "goorm-igw"
  }
}

# Create Route Table
resource "aws_route_table" "web-rt" {
  vpc_id = aws_vpc.goormVPC.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "web-route-table"
  }
}

resource "aws_route_table" "app-rt" {
  vpc_id = aws_vpc.goormVPC.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "app-route-table"
  }
}

# associate subnet with web route table
resource "aws_route_table_association" "web-rt-association_a" {
  subnet_id      = aws_subnet.zone-a.id
  route_table_id = aws_route_table.web-rt.id
}

resource "aws_route_table_association" "web-rt-association_c" {
  subnet_id      = aws_subnet.zone-c.id
  route_table_id = aws_route_table.web-rt.id
}

# associate subnet with app route table
resource "aws_route_table_association" "app-rt-association_a" {
  subnet_id      = aws_subnet.zone-a.id
  route_table_id = aws_route_table.app-rt.id
}

resource "aws_route_table_association" "app-rt-association_c" {
  subnet_id      = aws_subnet.zone-c.id
  route_table_id = aws_route_table.app-rt.id
}

# create aws security group
resource "aws_security_group" "goormVPC-sg" {
  name        = "goormVPC-sg"
  description = "Allow TLS inbound traffic"
  vpc_id      = aws_vpc.goormVPC.id

  ingress {
    description      = "TLS from VPC"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "goormVPC-sg"
  }
}

# create aws web load balancer
resource "aws_lb" "web-lb" {
  name = "web-lb"
  internal = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.goormVPC-sg.id]
  subnets = [aws_subnet.zone-a.id, aws_subnet.zone-c.id]
}

resource "aws_lb_listener" "web-lb-listener" {
  load_balancer_arn = aws_lb.web-lb.arn
  port = "80"
  protocol = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.web-tg.arn
  }
}

resource "aws_lb_target_group" "web-tg" {
  name = "web-tg"
  target_type = "instance"
  port = 80
  protocol = "HTTP"
  vpc_id = aws_vpc.goormVPC.id
}

resource "aws_launch_template" "web-lt" {
  name = "web-lt"
  image_id = "ami-05c13eab67c5d8861"
  instance_type = "t3.micro"
  key_name = "ubuntu"

  user_data = filebase64("${path.module}/server.sh")

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size = 8
      volume_type = "gp2"
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups = [aws_security_group.goormVPC-sg.id]
  }
}

# create aws web autoscaling group
resource "aws_autoscaling_group" "web-asg" {
  name = "web-asg"
  max_size = 2
  min_size = 2
  desired_capacity = 2
  health_check_type = "ELB"
  target_group_arns = [aws_lb_target_group.web-tg.arn]
  vpc_zone_identifier = [aws_subnet.zone-a.id, aws_subnet.zone-c.id]

  launch_template {
    id = aws_launch_template.web-lt.id
    version = "$Latest"
  }
}

# create aws app load balancer
resource "aws_lb" "app-lb" {
  name = "app-lb"
  internal = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.goormVPC-sg.id]
  subnets = [aws_subnet.zone-a.id, aws_subnet.zone-c.id]
}

resource "aws_lb_listener" "app-lb-listener" {
  load_balancer_arn = aws_lb.app-lb.arn
  port = "80"
  protocol = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.app-tg.arn
  }
}

resource "aws_lb_target_group" "app-tg" {
  name = "app-tg"
  target_type = "instance"
  port = 80
  protocol = "HTTP"
  vpc_id = aws_vpc.goormVPC.id
}

resource "aws_launch_template" "app-lt" {
  name = "app-lt"
  image_id = "ami-0e01e66dacaf1454d"
  instance_type = "t3.micro"
  key_name = "ubuntu"

  user_data = filebase64("${path.module}/server.sh")

  block_device_mappings {
    device_name = "/dev/sda2"

    ebs {
      volume_size = 8
      volume_type = "gp2"
    }
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups = [aws_security_group.goormVPC-sg.id]
  }
}

# create aws web autoscaling group
resource "aws_autoscaling_group" "app-asg" {
  name = "app-asg"
  max_size = 2
  min_size = 2
  health_check_type = "ELB"
  desired_capacity = 2
  target_group_arns = [aws_lb_target_group.web-tg.arn]
  vpc_zone_identifier = [aws_subnet.zone-a.id, aws_subnet.zone-c.id]
  launch_template {
    id = aws_launch_template.app-lt.id
    version = "$Latest"
  }
}