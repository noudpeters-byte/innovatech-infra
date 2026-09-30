resource "aws_db_subnet_group" "db_subnet" {
  name       = "main-db-subnet-group"
  subnet_ids = [aws_subnet.private_db_a.id, aws_subnet.private_db_b.id]

  tags = { Name = "main-db-subnet-group" }
}

resource "aws_db_instance" "mysql_db" {
  identifier             = "nca-mysql"
  engine                 = "mysql"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = "ticketsdb"
  username               = "admin"
  password               = var.db_password
  storage_encrypted      = true
  publicly_accessible    = false
  multi_az               = false # set to true for real production (costs double)
  skip_final_snapshot    = true
  db_subnet_group_name   = aws_db_subnet_group.db_subnet.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  tags = { Name = "nca-mysql" }
}
