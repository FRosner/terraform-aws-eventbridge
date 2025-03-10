provider "aws" {
  region = "ap-southeast-1"

  # Make it faster by skipping something
  skip_get_ec2_platforms      = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_credentials_validation = true
  skip_requesting_account_id  = true
}

module "eventbridge" {
  source = "../../"

  bus_name = "${random_pet.this.id}-bus"

  attach_tracing_policy = true

  attach_kinesis_policy = true
  kinesis_target_arns   = [aws_kinesis_stream.this.arn]

  attach_sfn_policy = true
  sfn_target_arns   = [module.step_function.state_machine_arn]

  attach_sqs_policy = true
  sqs_target_arns = [
    aws_sqs_queue.queue.arn,
    aws_sqs_queue.fifo.arn,
    aws_sqs_queue.dlq.arn
  ]

  attach_cloudwatch_policy = true
  cloudwatch_target_arns   = [aws_cloudwatch_log_group.this.arn]

  rules = {
    orders = {
      description   = "Capture all order data"
      event_pattern = jsonencode({ "source" : ["myapp.orders"] })
      enabled       = false
    }
    emails = {
      description   = "Capture all emails data"
      event_pattern = jsonencode({ "source" : ["myapp.emails"] })
      enabled       = true
    }
  }

  targets = {
    orders = [
      {
        name              = "send-orders-to-sqs"
        arn               = aws_sqs_queue.queue.arn
        input_transformer = local.order_input_transformer
      },
      {
        name            = "send-orders-to-sqs-wth-dead-letter"
        arn             = aws_sqs_queue.queue.arn
        dead_letter_arn = aws_sqs_queue.dlq.arn
      },
      {
        name            = "send-orders-to-sqs-with-retry-policy"
        arn             = aws_sqs_queue.queue.arn
        dead_letter_arn = aws_sqs_queue.dlq.arn
        retry_policy = {
          maximum_retry_attempts       = 10
          maximum_event_age_in_seconds = 300
        }
      },
      {
        name             = "send-orders-to-fifo-sqs"
        arn              = aws_sqs_queue.fifo.arn
        dead_letter_arn  = aws_sqs_queue.dlq.arn
        message_group_id = "send-orders-to-fifo-sqs"
      },
      {
        name = "log-orders-to-cloudwatch"
        arn  = aws_cloudwatch_log_group.this.arn
      }
    ]

    emails = [
      {
        name            = "process-email-with-sfn"
        arn             = module.step_function.state_machine_arn
        attach_role_arn = true
      },
      {
        name              = "send-orders-to-kinesis"
        arn               = aws_kinesis_stream.this.arn
        dead_letter_arn   = aws_sqs_queue.dlq.arn
        input_transformer = local.order_input_transformer
        attach_role_arn   = true
      }
    ]
  }

  ######################
  # Additional policies
  ######################

  attach_policy_json = true
  policy_json        = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "xray:GetSamplingStatisticSummaries"
      ],
      "Resource": ["*"]
    }
  ]
}
EOF

  attach_policy_jsons = true
  policy_jsons = [<<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "xray:*"
      ],
      "Resource": ["*"]
    }
  ]
}
EOF
  ]
  number_of_policy_jsons = 1

  attach_policy = true
  policy        = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"

  attach_policies    = true
  policies           = ["arn:aws:iam::aws:policy/AWSXrayReadOnlyAccess"]
  number_of_policies = 1

  attach_policy_statements = true
  policy_statements = {
    dynamodb = {
      effect    = "Allow",
      actions   = ["dynamodb:BatchWriteItem"],
      resources = ["arn:aws:dynamodb:eu-west-1:052212379155:table/Test"]
    },
    s3_read = {
      effect    = "Deny",
      actions   = ["s3:HeadObject", "s3:GetObject"],
      resources = ["arn:aws:s3:::my-bucket/*"]
    }
  }

  ###########################
  # END: Additional policies
  ###########################
}

locals {
  order_input_transformer = {
    input_paths = {
      order_id = "$.detail.order_id"
    }
    input_template = <<EOF
    {
      "id": <order_id>
    }
    EOF
  }
}

##################
# Extra resources
##################

resource "random_pet" "this" {
  length = 2
}

resource "aws_kinesis_stream" "this" {
  name        = random_pet.this.id
  shard_count = 1
}

resource "aws_sqs_queue" "queue" {
  name = "${random_pet.this.id}-queue"
}

resource "aws_sqs_queue" "fifo" {
  name                        = "${random_pet.this.id}.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
}

resource "aws_sqs_queue" "dlq" {
  name = "${random_pet.this.id}-dlq"
}

resource "aws_sqs_queue_policy" "queue" {
  queue_url = aws_sqs_queue.queue.id
  policy    = data.aws_iam_policy_document.queue.json
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid     = "events-policy"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [
      aws_sqs_queue.queue.arn,
      aws_sqs_queue.fifo.arn
    ]
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name = "/aws/events/${random_pet.this.id}"

  tags = {
    Name = "${random_pet.this.id}-log-group"
  }
}

################
# Step Function
################

module "step_function" {
  source  = "terraform-aws-modules/step-functions/aws"
  version = "~> 2.0"

  name = random_pet.this.id

  definition = jsonencode(yamldecode(templatefile("sfn.asl.yaml", {})))

  trusted_entities = ["events.amazonaws.com"]

  service_integrations = {
    stepfunction = {
      stepfunction = ["*"]
    }
  }
}
