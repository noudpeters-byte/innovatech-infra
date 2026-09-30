# ---------- Application Load Balancer (public entry point) ----------
resource "aws_lb" "web_alb" {
  name               = "nca-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = { Name = "nca-alb" }
}

resource "aws_lb_target_group" "web_tg" {
  name     = "nca-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.nca_vpc.id

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "nca-web-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}
