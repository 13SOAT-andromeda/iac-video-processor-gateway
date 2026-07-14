data "aws_lambda_function" "authentication" {
  function_name = "video-processor-authentication"
}

data "aws_lambda_function" "authorizer" {
  function_name = "video-processor-authorizer"
}

data "aws_vpc" "selected" {
  filter {
    name   = "tag:Name"
    values = ["video-processor-vpc-local"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["*-private-*"]
  }
}
