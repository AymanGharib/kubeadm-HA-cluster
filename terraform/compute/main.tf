data "aws_ami" "server_ami" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]

  }
}

resource "aws_instance" "master-node" {


  instance_type = var.instance_type
  ami           = data.aws_ami.server_ami.id




  vpc_security_group_ids = [var.master_sg]

  subnet_id = var.public_subnet_id


  user_data = base64encode(templatefile(var.user_data_path, {







  }))






  root_block_device {
    volume_size = var.vol_size
  }
  key_name = aws_key_pair.ansible-key.key_name


  tags = {
    Name = "Kubernetes-Master"
  }

}




resource "aws_instance" "ansible-server" {


  instance_type = var.instance_type
  ami           = data.aws_ami.server_ami.id




  vpc_security_group_ids = [var.ansible_sg]

  subnet_id = var.public_subnet_id

  key_name  = aws_key_pair.ssh_auth.key_name
  user_data = base64encode(templatefile(var.worker_data_path, {}))






  root_block_device {
    volume_size = var.vol_size
  }



  tags = {
    Name = "Ansible-server"
  }

}




resource "aws_key_pair" "ssh_auth" {
  public_key = file(var.public_key_path)
  key_name   = var.key_name

}


resource "aws_key_pair" "ansible-key" {
  public_key = file(var.ansible_key_path)
  key_name   = var.ansible_key_name

}

















resource "aws_launch_template" "worker-lt" {
  name_prefix            = "worker-node-"
  image_id               = data.aws_ami.server_ami.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [var.worker_sgs]
  key_name               = aws_key_pair.ansible-key.key_name
  user_data              = base64encode(templatefile(var.worker_data_path, {}))
  block_device_mappings {
    device_name = "/dev/sda1" # Default root device for Ubuntu

    ebs {
      volume_size           = var.vol_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }


  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Kubernetes-Worker"
    }
  }
}


resource "aws_autoscaling_group" "worker_asg" {
  depends_on          = [aws_instance.master-node]
  desired_capacity    = var.worker_count
  min_size            = 1
  max_size            = 5
  vpc_zone_identifier = [var.public_subnet_id]
  launch_template {
    id      = aws_launch_template.worker-lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "Kubernetes-Worker"
    propagate_at_launch = true
  }
}
