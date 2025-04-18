output "master_sg" {
  value = aws_security_group.master_node_sg.id
}
output "private_subnet_id" {
  value = aws_subnet.private_subnet.id
}
output "public_subnet_id" {
  value = aws_subnet.public_subnet.id
}
output "worker_sg" {
  value = aws_security_group.worker_node_sg.id
}
output "ansible_sg" {
   value = aws_security_group.ansible_sg.id
}