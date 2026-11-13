# ==========================================
# DAY 2: VIRTUAL PRIVATE CLOUD NETWORKING
# ==========================================
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.app_name}-vpc" }
}

resource "aws_subnet" "pub" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.app_name}-public-subnet-${count.index}" }
}

resource "aws_subnet" "priv" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${var.app_name}-private-subnet-${count.index}" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.app_name}-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.pub[0].id
  tags          = { Name = "${var.app_name}-nat-gw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.app_name}-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.app_name}-private-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.pub[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.priv[count.index].id
  route_table_id = aws_route_table.private.id
}

# ==========================================
# LAYER BOUNDARY SECURITY GROUPS
# ==========================================
resource "aws_security_group" "alb" {
  name        = "${var.app_name}-alb-sg"
  description = "Allow public inbound HTTP traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
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

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.app_name}-ecs-tasks-sg"
  description = "Allow routed traffic from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "${var.app_name}-db-sg"
  description = "Allow database traffic from application layer only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==========================================
# DAYS 8 & 9: ENCRYPTED RDS POSTGRES & SECRETS
# ==========================================
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_secret" {
  name                    = "${var.app_name}-db-credentials-v2"
  recovery_window_in_days = 0 
}

resource "aws_secretsmanager_secret_version" "db_secret_val" {
  secret_id = aws_secretsmanager_secret.db_secret.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.app_name}-db-subnet-group"
  subnet_ids = aws_subnet.priv[*].id
}

resource "aws_db_instance" "postgres" {
  identifier             = "${var.app_name}-db"
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "15.7"
  instance_class         = "db.t4g.micro"
  db_name                = var.db_name
  username               = var.db_username
  password               = random_password.db_password.result
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  skip_final_snapshot    = true
}

# ==========================================
# DAYS 5 & 6: REPOSITORIES & ECS CLUSTER
# ==========================================
resource "aws_ecr_repository" "backend" {
  name                 = "${var.app_name}-backend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.app_name}-frontend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecs_cluster" "main" {
  name = "${var.app_name}-cluster"
}

# ==========================================
# APPLICATION ROLE PERMISSIONS
# ==========================================
resource "aws_iam_role" "ecs_execution_role" {
  name = "${var.app_name}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "ecs_secrets_policy" {
  name = "${var.app_name}-ecs-secrets-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.db_secret.arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_secrets" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = aws_iam_policy.ecs_secrets_policy.arn
}

resource "aws_iam_role" "ecs_task_role" {
  name = "${var.app_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# ==========================================
# DAY 15: RUNTIME TELEMETRY TRACKING
# ==========================================
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.app_name}"
  retention_in_days = 1
}

# ==========================================
# DAY 7: APPLICATION LOAD BALANCER (ALB)
# ==========================================
resource "aws_lb" "main" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.pub[*].id
}

resource "aws_lb_target_group" "backend" {
  name        = "${var.app_name}-tg-backend"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    port                = "5000"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "frontend" {
  name        = "${var.app_name}-tg-frontend"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/"
    port                = "80"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_listener_rule" "backend_routing" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*", "/health"]
    }
  }
}

# ==========================================
# COMPUTE BLUEPRINT & SERVICES (FARGATE)
# ==========================================
resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.app_name}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name      = "backend"
    image     = "${aws_ecr_repository.backend.repository_url}:latest"
    essential = true
    portMappings = [{
      containerPort = 5000
      hostPort      = 5000
    }]
    environment = [
      { name = "DB_HOST", value = aws_db_instance.postgres.address },
      { name = "DB_NAME", value = aws_db_instance.postgres.db_name },
      { name = "DB_PORT", value = "5432" }
    ]
    secrets = [
{ name = "DB_USER", valueFrom = "${aws_secretsmanager_secret.db_secret.arn}:username::" },
{ name = "DB_PASSWORD", valueFrom = "${aws_secretsmanager_secret.db_secret.arn}:password::" }
]
logConfiguration = {
logDriver = "awslogs"
options = {
"awslogs-group"         = aws_cloudwatch_log_group.ecs.name
"awslogs-region"        = var.aws_region
"awslogs-stream-prefix" = "backend"
}
}
}])
}
resource "aws_ecs_task_definition" "frontend" {
family                   = "${var.app_name}-frontend"
network_mode             = "awsvpc"
requires_compatibilities = ["FARGATE"]
cpu                      = "256"
memory                   = "512"
execution_role_arn       = aws_iam_role.ecs_execution_role.arn
task_role_arn            = aws_iam_role.ecs_task_role.arn
container_definitions = jsonencode([{
name      = "frontend"
image     = "${aws_ecr_repository.frontend.repository_url}:latest"
essential = true
portMappings = [{
containerPort = 80
hostPort      = 80
}]
logConfiguration = {
logDriver = "awslogs"
options = {
"awslogs-group"         = aws_cloudwatch_log_group.ecs.name
"awslogs-region"        = var.aws_region
"awslogs-stream-prefix" = "frontend"
}
}
}])
}
resource "aws_ecs_service" "backend" {
name            = "${var.app_name}-backend"
cluster         = aws_ecs_cluster.main.id
task_definition = aws_ecs_task_definition.backend.arn
lifecycle {
  ignore_changes = [task_definition]
}
desired_count   = 0
launch_type     = "FARGATE"
network_configuration {
subnets         = aws_subnet.priv[*].id
security_groups = [aws_security_group.ecs_tasks.id]
}
load_balancer {
target_group_arn = aws_lb_target_group.backend.arn
container_name   = "backend"
container_port   = 5000
}
depends_on = [aws_lb_listener.http, aws_db_instance.postgres]

}
resource "aws_ecs_service" "frontend" {
name            = "${var.app_name}-frontend"
cluster         = aws_ecs_cluster.main.id
task_definition = aws_ecs_task_definition.frontend.arn
lifecycle {
  ignore_changes = [task_definition]
}
desired_count   = 0
launch_type     = "FARGATE"
network_configuration {
subnets          = aws_subnet.pub[*].id
security_groups  = [aws_security_group.ecs_tasks.id]
assign_public_ip = true
}
load_balancer {
target_group_arn = aws_lb_target_group.frontend.arn
container_name   = "frontend"
container_port   = 80
}
depends_on = [aws_lb_listener.http]
}