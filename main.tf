# create an EC2 instance to host the catalogue service
resource "aws_instance" "main" {
    ami = local.ami_id
    instance_type = "t3.micro"
    vpc_security_group_ids = [local.sg_id]
    subnet_id = local.private_subnet_id # use private subnet to host the catalogue service as it is not exposed to the internet and we will access it through the bastion host

    tags = merge (
        local.common_tags,
        {
            Name = "${local.common_name_suffix}-${var.component}" # roboshop-dev-catalogue
        }
    )
  
}

#configure instance using remote-exec provisioner through terraform_data
resource "terraform_data" "main" {
    triggers_replace = [
        aws_instance.main.id,
    ]

    connection {
        type = "ssh"
        user = "ec2-user"
        password = "DevOps321"
        host = aws_instance.main.private_ip 
    }

    # terraform copies this file to instance and then executes it
    provisioner "file" {
      source = "bootstrap.sh"
      destination = "/tmp/bootstrap.sh"
    }

    provisioner "remote-exec" {
      inline = [ 
        "set -x",
        "chmod +x /tmp/bootstrap.sh",
        "sudo sh /tmp/bootstrap.sh ${var.component} ${var.environment}"
       ]
    }
}   

#stopping the instance to take AMI image
   resource "aws_ec2_instance_state" "main" {
    instance_id = aws_instance.main.id
    state = "stopped"
    depends_on = [ terraform_data.main ]
       
   }

   resource "aws_ami_from_instance" "main" {
    name = "${local.common_name_suffix}-${var.component}-ami" # roboshop-dev-catalogue-ami
    description = "AMI for ${var.component} service"
    source_instance_id = aws_instance.main.id
    depends_on = [ aws_ec2_instance_state.main ]
    tags = merge (
        local.common_tags,
        {
            Name = "${local.common_name_suffix}-${var.component}-ami" # roboshop-dev-catalogue-ami
        }
    )
     
   }

#target group for catalogue service
   resource "aws_lb_target_group" "main" {
    name = "${local.common_name_suffix}-${var.component}-tg" # roboshop-dev-catalogue-tg
    port = local.tg_port  # if frontend port is 80, otherwise it is 8080
    protocol = "HTTP"
    vpc_id = local.vpc_id
    health_check {
        healthy_threshold = 2
        unhealthy_threshold = 2 
        interval = 10
        timeout = 2
        port = local.tg_port
        path = local.health_check_path # if component is frontend then health check path is / otherwise it is /health
        protocol = "HTTP"
        matcher = "200-299"
    }
    tags = merge (
        local.common_tags,
        {
            Name = "${local.common_name_suffix}-${var.component}-tg" # roboshop-dev-catalogue-tg
        }
    )
   }

# launch template for catalogue service
   resource "aws_launch_template" "main" {
    name = "${local.common_name_suffix}-${var.component}-lt" # roboshop-dev-catalogue-lt
    image_id = aws_ami_from_instance.main.id
    instance_initiated_shutdown_behavior = "terminate"
    instance_type = "t3.micro"
    vpc_security_group_ids = [local.sg_id]

    #when we run terraform apply again, a new version will be created with new AMI id
    update_default_version = true
    # tags attached to the instance created by the launch template
    tag_specifications {
        resource_type = "instance"

        tags = merge (
            local.common_tags,
            {
                Name = "${local.common_name_suffix}-${var.component}" # roboshop-dev-catalogue
            }
        )
    }
   

    # tags attached to the volume created by the instance
    tag_specifications {
        resource_type = "volume"     
        tags = merge (
            local.common_tags,
            {
                Name = "${local.common_name_suffix}-${var.component}-lt" # roboshop-dev-catalogue-lt
            }
        )
    }
      

    # tags attached to the launch template
    tags = merge (
        local.common_tags,
        {
            Name = "${local.common_name_suffix}-${var.component}-lt" # roboshop-dev-catalogue-lt
        }
    )
}

# auto scaling group for catalogue service
   resource "aws_autoscaling_group" "main" {
    name = "${local.common_name_suffix}-${var.component}-asg" # roboshop-dev-catalogue-asg
    max_size = 10
    min_size = 1
    health_check_grace_period = 100
    health_check_type = "ELB"
    desired_capacity = 1
    force_delete = false
    vpc_zone_identifier = local.private_subnet_ids
    launch_template {
        id = aws_launch_template.main.id
        version = aws_launch_template.main.latest_version
    }
    target_group_arns = [aws_lb_target_group.main.arn]

    instance_refresh {
      strategy = "Rolling"
      preferences {
        min_healthy_percentage = 50 #atleast 50% of the instances should be up and running
      }
      triggers = [ "launch_template" ]
    }

   dynamic "tag" { #we will get the iterator with name as value
      for_each = merge(
        local.common_tags,
        {
            Name = "${local.common_name_suffix}-${var.component}" # roboshop-dev-catalogue
        }
      )
      content {
        key = tag.key
        value = tag.value
        propagate_at_launch = true
      }
    }

    timeouts {
      delete = "15m"
    }
   }

   #autoscalling policy to scale up the instances when CPU utilization is more than 75%
   resource "aws_autoscaling_policy" "main" {
    name = "${local.common_name_suffix}-${var.component}-scale-up-policy" # roboshop-dev-catalogue-scale-up-policy
    autoscaling_group_name = aws_autoscaling_group.main.name
    policy_type = "TargetTrackingScaling"
    target_tracking_configuration {
      predefined_metric_specification {
        predefined_metric_type = "ASGAverageCPUUtilization"
      }
      target_value = 75.0
    }
   }

   # listerner rule 
    resource "aws_lb_listener_rule" "main" {
     listener_arn = local.listener_arn # if component is frontend then it is frontend alb listener arn otherwise it is backend alb listener arn
     priority = var.rule_priority # we will pass the priority as variable from the module
     action {
        type = "forward"
        target_group_arn = aws_lb_target_group.main.arn
     }
     condition {
       host_header {
        values = [local.host_context] # if component is frontend then it is {project_name}-{environment}.{domain_name} otherwise it is {component}.backend-alb-{environment}.{domain_name}
       }
     }
    }

    #deleteing the instance
    resource "terraform_data" "main_local" {
      triggers_replace = [
        aws_instance.main.id,
      ]

      depends_on = [ aws_autoscaling_policy.main ]
      provisioner "local-exec" {
        command = "aws ec2 terminate-instances --instance-ids ${aws_instance.main.id}"
      } 
    }