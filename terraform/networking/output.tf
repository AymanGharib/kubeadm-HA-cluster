output "master_sg" {
  value = aws_security_group.master_node_sg.id
}
output "private_subnet_id" {
  value = aws_subnet.private_subnet.id
}
output "worker_sg" {
  value = aws_security_group.worker_node_sg.name
}