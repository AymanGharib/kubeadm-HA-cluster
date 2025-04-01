module "networking" {
    source = "./networking"
    cidr_block = var.cidr_block
    public_subnet_cidr = [cidrsubnet(var.cidr_block, 8, 1)] 
    private_subnet_cidr=  [cidrsubnet(var.cidr_block, 8, 2)] 


}

module "compute" {
  source = "./compute"
  instance_type  = "t3.micro"
  master_sg = module.networking.master_sg
  private_subnet_id = module.networking.private_subnet_id
  vol_size =  8 
  worker_sgs  = module.networking.worker_sg
  worker_count = 2 
}