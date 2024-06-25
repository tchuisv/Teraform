#creating the provider

provider "aws" {
  region = "us-east-2"
}

#creating resources

resource "aws_vpc" "voltaire-infra" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "voltaire-infra"
  }
}

resource "aws_subnet" "pub" {
  count             = 2
  vpc_id            = aws_vpc.voltaire-infra.id
  cidr_block        = cidrsubnet(aws_vpc.voltaire-infra.cidr_block, 8, count.index) # this the cidr of the public sub > vpc cidr, increment of the base bit, index for unique subnet
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  tags = {
    Name = "public-subnet-${count.index + 1}"
  }

}

resource "aws_subnet" "priv" {
  count             = 2
  vpc_id            = aws_vpc.voltaire-infra.id
  cidr_block        = cidrsubnet(aws_vpc.voltaire-infra.cidr_block, 8, count.index + 2) # this the cidr of the public sub > vpc cidr, increment of the base bit, index for unique subnet
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  tags = {
    Name = "private-subnet-${count.index + 1}"
  }

}

# Get availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

#IGW to route traffic to the internet

resource "aws_internet_gateway" "vol-IGW" {
  vpc_id = aws_vpc.voltaire-infra.id
  tags = {
    Name = "vol-IGW"
  }
}

#create an Elastic IP for the NAT GW
resource "aws_eip" "EIP-NAT-GW" {
  count  = 2 #creating 2 for the 2 private networks
  domain = "vpc"

  tags = {
    Name = "EIP-NAT-${count.index + 1}"
  }
}

#create NAT GW for each Private subnet
resource "aws_nat_gateway" "vol-NAT" {
  count         = 2
  allocation_id = aws_eip.EIP-NAT-GW[count.index].id
  subnet_id     = aws_subnet.pub[count.index].id # to the public Sub. Default ID
  tags = {
    Name = "vol-NAT-${count.index + 1}"
  }

}

#Route Table for the public subnet

resource "aws_route_table" "public-RT" {
  vpc_id = aws_vpc.voltaire-infra.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.vol-IGW.id
  }
  tags = {
    Name = "public-RT"
  }
}

#Route Table for the private subnet

resource "aws_route_table" "private-RT" {
  vpc_id = aws_vpc.voltaire-infra.id
  tags = {
    Name = "private-RT"
  }
}

#create route from the private RT to the NAT
resource "aws_route" "priv-to-NAT" {
  count                  = length(aws_subnet.priv)
  route_table_id         = aws_route_table.private-RT.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.vol-NAT[count.index].id

}




# Associate the public subnet to the public RT
resource "aws_route_table_association" "RT-pub" {
  count          = length(aws_subnet.pub)
  subnet_id      = aws_subnet.pub[count.index].id
  route_table_id = aws_route_table.public-RT.id
}

# Associate the private subnet to the private RT
resource "aws_route_table_association" "RT-priv" {
  count          = length(aws_subnet.priv)
  subnet_id      = aws_subnet.priv[count.index].id
  route_table_id = aws_route_table.private-RT.id
}



#Create Security Group for pub instances
resource "aws_security_group" "pub-SG" {
  vpc_id = aws_vpc.voltaire-infra.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" #Allow outbound traffic from all ports
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "pub-SG"
  }

}

# Security Group for Private Instances
resource "aws_security_group" "priv-SG" {
  vpc_id = aws_vpc.voltaire-infra.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"            #everything 
    cidr_blocks = ["10.0.0.0/16"] # Allow all internal traffic
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # Allow all outbound traffic
  }

  tags = {
    Name = "priv-SG"
  }

}

# Define security ALB
resource "aws_security_group" "alb_SG" {
  vpc_id = aws_vpc.voltaire-infra.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
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



# Key Pair
resource "aws_key_pair" "inst_key" {
  key_name   = "my-pub-key"
  public_key = file("~/.ssh/id_rsa.pub") # dir of keypair
}

locals {
  launch_template_configs = [
    {
      name                = "public-lt"
      subnet_id           = aws_subnet.pub[*].id
      sg_id               = aws_security_group.pub-SG.id
      associate_public_ip = true
    },
    {
      name                = "private-lt"
      subnet_id           = aws_subnet.priv[*].id
      sg_id               = aws_security_group.priv-SG.id
      associate_public_ip = false
    }
  ]
}

resource "aws_launch_template" "inst-Templ" {
  count         = length(local.launch_template_configs)
  name          = local.launch_template_configs[count.index].name
  image_id      = "ami-07a5db12eede6ff87" # free 
  instance_type = "t2.micro"

  dynamic "network_interfaces" {
    for_each = local.launch_template_configs[count.index].subnet_id
    content {
      device_index                = 0
      subnet_id                   = network_interfaces.value
      associate_public_ip_address = local.launch_template_configs[count.index].associate_public_ip
      security_groups             = [local.launch_template_configs[count.index].sg_id]
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "templ-instance-${local.launch_template_configs[count.index].name}"
    }
  }
}

resource "aws_autoscaling_group" "public_ASG" {
  desired_capacity = 3
  max_size         = 5
  min_size         = 2
  launch_template {
    id      = aws_launch_template.inst-Templ[0].id
    version = "$Latest"
  }
  vpc_zone_identifier       = aws_subnet.pub[*].id
  health_check_type         = "EC2"
  health_check_grace_period = 300

  #   tags = [
  #     {
  #       key                 = "Name"
  #       value               = "public-asg"
  #       propagate_at_launch = true
  #     },
  #   ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "private_ASG" {
  desired_capacity = 3
  max_size         = 5
  min_size         = 2
  launch_template {
    id      = aws_launch_template.inst-Templ[1].id
    version = "$Latest"
  }
  vpc_zone_identifier       = aws_subnet.priv[*].id
  health_check_type         = "EC2"
  health_check_grace_period = 300

  # tags = [
  #   {
  #     key                 = "Name"
  #     value               = "private-asg"
  #     propagate_at_launch = true
  #   },
  # ]

  lifecycle {
    create_before_destroy = true
  }
}


# Define ALB and attach to private subnet
resource "aws_lb" "vol-ALB" {
  name               = "vol-ALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_SG.id]
  subnets            = [aws_subnet.priv[0].id, aws_subnet.priv[1].id]

  enable_deletion_protection = false

  tags = {
    Name = "private-net-alb"
  }
}



# Define ALB Listeners
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.vol-ALB.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vol-alb-tg.arn
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.vol-ALB.arn
  port              = 443
  protocol          = "HTTPS"
  #ssl_policy        = "ELBSecurityPolicy-2016-08"
  #certificate_arn   = "arn:aws:acm:us-west-2:123456789012:certificate/abcd1234-5678-90ab-cdef-12345EXAMPLE"  # Replace with your ACM certificate ARN

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vol-alb-tg.arn # this login is not right. Forwarding HTTPS traffic to HHTP TG EXPLAIN
  }
}

# Define Target Groups
resource "aws_lb_target_group" "vol-alb-tg" {
  name        = "vol-alb-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.voltaire-infra.id
  target_type = "instance"

  health_check {
    path     = "/"
    interval = 30
    timeout  = 5

  }
}




































# # Launch Template
# resource "aws_launch_template" "inst-templ" {
#   name          = "instance-template"
#   image_id      = "ami-07a5db12eede6ff87"  # free 
#   instance_type = "t2.micro"      

#   key_name = aws_key_pair.inst_key.key_name  # calling the key

#   network_interfaces {
#     device_index = 0
#     subnet_id = aws_subnet.pub[count.index].id #default subnet
#     associate_public_ip_address = true  #initail subnetID but the ASG will ultimately decide subnet based on VPC zone identifier
#     security_groups = [aws_security_group.pub-SG.id]
#   }

#   user_data = base64encode("#!/bin/bash\necho 'Hello, Voltaire's World!' > /var/www/html/index.html")

#   tag_specifications {
#     resource_type = "instance"
#     tags = {
#       Name = "my-ints"
#     }
#   }
# }


# # Auto Scaling Group
# resource "aws_autoscaling_group" "vol-ASG" {
#   desired_capacity = 3
#   max_size         = 5
#   min_size         = 2
#   launch_template {
#     id      = aws_launch_template.inst-templ.id
#     version = "$Latest"
#   }

#   vpc_zone_identifier  =  [aws_subnet.pub[*].id, aws_subnet.priv[*].id]  # this is unclear
#   health_check_type    = "EC2"
#   health_check_grace_period = 300

# #    tags = [
# #     {
# #       key                 = "ASG-inst"
# #       value               = "inst-asg"
# #       propagate_at_launch = true
# #     },
# #   ] 

#   lifecycle {
#     create_before_destroy = true
#   }
# }
























