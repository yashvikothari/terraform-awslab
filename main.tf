terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}


provider "aws" {
  region = var.aws_region
}


variable "aws_region" {
  type    = string
  default = "us-east-1"
}


variable "photos_bucket_name" {
  type        = string
  description = "Target S3 bucket for employee profile photos"
}


# 1. Dynamically fetch the latest Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]


  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}


# 2. Least-Privilege IAM Role & Instance Profile for EC2
resource "aws_iam_role" "employee_app_role" {
  name = "EmployeeWebAppRole"


  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}


resource "aws_iam_role_policy" "employee_app_permissions" {
  name = "EmployeeAppS3DynamoLeastPrivilege"
  role = aws_iam_role.employee_app_role.id


  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowPhotoBucketOperations"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.photos_bucket_name}",
          "arn:aws:s3:::${var.photos_bucket_name}/*"
        ]
      },
      {
        Sid      = "AllowEmployeeTableOperations"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Scan", "dynamodb:Query", "dynamodb:UpdateItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:*:table/Employees"
      },
      {
        Sid      = "AllowSSMSessionManagerForZeroSSHAccess"
        Effect   = "Allow"
        Action   = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })
}


resource "aws_iam_instance_profile" "employee_app_profile" {
  name = "EmployeeWebAppInstanceProfile"
  role = aws_iam_role.employee_app_role.name
}


# 3. Stateful Security Group (Port 80 Inbound, Egress Allowed)
resource "aws_security_group" "web_sg" {
  name        = "employee-directory-web-sg"
  description = "Allow HTTP inbound traffic"


  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  egress {
    description = "Allow outbound HTTPS/HTTP for package updates and AWS API calls"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# 4. EC2 Instance with User Data Bootstrap & IMDSv2 Enforced
resource "aws_instance" "employee_app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  iam_instance_profile        = aws_iam_instance_profile.employee_app_profile.name
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true


  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Enforces IMDSv2 against SSRF attacks
    http_put_response_hop_limit = 1
  }


  user_data = <<-EOF
    #!/bin/bash -ex
    wget https://aws-tc-largeobjects.s3-us-west-2.amazonaws.com/DEV-AWS-MO-GCNv2/FlaskApp.zip
    unzip FlaskApp.zip
    cd FlaskApp/
    dnf -y install python3-pip stress
    pip3 install -r requirements.txt
    export PHOTOS_BUCKET=${var.photos_bucket_name}
    export AWS_DEFAULT_REGION=${var.aws_region}
    export DYNAMO_MODE=on
    FLASK_APP=application.py /usr/local/bin/flask run --host=0.0.0.0 --port=80 &
  EOF


  tags = {
    Name        = "EmployeeDirectoryApp-Prod"
    ManagedBy   = "Terraform"
    Environment = "Lab-Proof"
  }
}




