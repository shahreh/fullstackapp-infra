resource "aws_launch_template" "vpt_launchtemplate" {
  name = var.psql_template_name

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_size           = 40
      volume_type           = "gp2"
      delete_on_termination = false
    }
  }

  #ebs_optimized = true

  image_id = data.aws_ami.ubuntu_ami.id

  instance_type = var.psql_launch_type

  monitoring {
    enabled = true
  }

  placement {
    tenancy = "default"
  }

  vpc_security_group_ids = [aws_security_group.psql_sg.id]

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "VPTech-psql"
    }
  }

  key_name = var.psql_keypair

  user_data = filebase64("scripts/ec2_initialization.sh")

  iam_instance_profile {
    arn = aws_iam_instance_profile.psql_profile.arn
  }

  tags = merge(
    local.common_tags,
    {
      Name = "VPTech-PSQL-LT"
    }
  )

}