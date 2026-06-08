$ErrorActionPreference = "Stop"

$REGION = "us-east-1"
$ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)

Write-Host ""
Write-Host "============================================="
Write-Host " AIOps — IAM Setup (PowerShell)"
Write-Host " Account : $ACCOUNT_ID"
Write-Host " Region  : $REGION"
Write-Host "============================================="
Write-Host ""

# =============================================================================
# ROLE 1: aiops-lambda-role
# =============================================================================
$LAMBDA_ROLE_NAME = "aiops-lambda-role"
Write-Host "[1/2] Creating IAM role: $LAMBDA_ROLE_NAME"

$LAMBDA_TRUST_POLICY = '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}'

try {
    $roleExists = aws iam get-role --role-name $LAMBDA_ROLE_NAME 2>$null
    Write-Host "  ✓ Role already exists: $LAMBDA_ROLE_NAME"
} catch {
    aws iam create-role --role-name $LAMBDA_ROLE_NAME --assume-role-policy-document $LAMBDA_TRUST_POLICY --description "Role for AIOps Lambda functions" --query 'Role.RoleName' --output text | Out-Null
    Write-Host "  ✓ Created: $LAMBDA_ROLE_NAME"
}

aws iam attach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" | Out-Null
Write-Host "  ✓ Attached: AWSLambdaBasicExecutionRole"

$LAMBDA_INLINE_POLICY = '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogsRead",
      "Effect": "Allow",
      "Action": [
        "logs:FilterLogEvents",
        "logs:StartQuery",
        "logs:GetQueryResults",
        "logs:StopQuery",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EKSRead",
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListNodegroups",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    }
  ]
}'

aws iam put-role-policy --role-name $LAMBDA_ROLE_NAME --policy-name "aiops-lambda-inline-policy" --policy-document $LAMBDA_INLINE_POLICY | Out-Null
Write-Host "  ✓ Inline policy applied: CloudWatch Logs read + EKS describe"

# =============================================================================
# ROLE 2: aiops-bedrock-agent-role
# =============================================================================
$AGENT_ROLE_NAME = "aiops-bedrock-agent-role"
Write-Host ""
Write-Host "[2/2] Creating IAM role: $AGENT_ROLE_NAME"

$BEDROCK_TRUST_POLICY = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "bedrock.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "$ACCOUNT_ID"
        }
      }
    }
  ]
}
"@

try {
    $roleExists = aws iam get-role --role-name $AGENT_ROLE_NAME 2>$null
    Write-Host "  ✓ Role already exists: $AGENT_ROLE_NAME"
} catch {
    aws iam create-role --role-name $AGENT_ROLE_NAME --assume-role-policy-document $BEDROCK_TRUST_POLICY --description "Role for Bedrock Agent" --query 'Role.RoleName' --output text | Out-Null
    Write-Host "  ✓ Created: $AGENT_ROLE_NAME"
}

$AGENT_INLINE_POLICY = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeLambdaFunctions",
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": [
        "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:aiops-fetch-logs",
        "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:aiops-fetch-metrics",
        "arn:aws:lambda:$REGION:$ACCOUNT_ID:function:aiops-fetch-health"
      ]
    },
    {
      "Sid": "InvokeBedrockModels",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": "arn:aws:bedrock:$REGION::foundation-model/*"
    }
  ]
}
"@

aws iam put-role-policy --role-name $AGENT_ROLE_NAME --policy-name "aiops-bedrock-agent-inline-policy" --policy-document $AGENT_INLINE_POLICY | Out-Null
Write-Host "  ✓ Inline policy applied: Lambda invoke + Bedrock model invoke"

Write-Host ""
Write-Host "============================================="
Write-Host " Done!"
Write-Host "============================================="
Write-Host ""
Write-Host " Roles created:"
Write-Host "  - $LAMBDA_ROLE_NAME"
Write-Host "    ARN: arn:aws:iam::$ACCOUNT_ID`:role/$LAMBDA_ROLE_NAME"
Write-Host ""
Write-Host "  - $AGENT_ROLE_NAME"
Write-Host "    ARN: arn:aws:iam::$ACCOUNT_ID`:role/$AGENT_ROLE_NAME"
Write-Host ""
