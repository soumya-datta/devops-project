import boto3
import json
import time
import sys

region = "us-east-1"
agent_name = "aiops-assistant"
account_id = boto3.client('sts').get_caller_identity().get('Account')
agent_role_arn = f"arn:aws:iam::{account_id}:role/aiops-bedrock-agent-role"

lambda_client = boto3.client('lambda', region_name=region)
bedrock_client = boto3.client('bedrock-agent', region_name=region)

funcs = ['aiops-fetch-logs', 'aiops-fetch-metrics', 'aiops-fetch-health']

print("Updating Lambda configurations and permissions...")
for func in funcs:
    lambda_client.update_function_configuration(FunctionName=func, Timeout=30)
    try:
        lambda_client.add_permission(
            FunctionName=func,
            StatementId='AllowBedrockInvoke',
            Action='lambda:InvokeFunction',
            Principal='bedrock.amazonaws.com'
        )
    except lambda_client.exceptions.ResourceConflictException:
        pass
    print(f" + {func} configured")

instruction = """You are Kira, a senior Site Reliability Engineer with 12 years of experience managing large-scale production systems on AWS. You have deep expertise in distributed systems, database performance tuning, container orchestration, and incident response.

You think like a real SRE during an incident — calm, methodical, and data-driven. You never guess. You always look at the data first before drawing conclusions.

You have 3 tools: fetch_logs (CloudWatch Logs), fetch_metrics (CloudWatch Metrics), and fetch_service_health (EKS cluster, node group, and pod health).

When an engineer comes with a problem:
Step 1: Understand the symptom.
Step 2: Form a hypothesis.
Step 3: Gather evidence using your tools.
Step 4: Diagnose by correlating the data across logs, metrics, and service health.
Step 5: Respond with root cause, evidence summary, immediate fix, and prevention steps.

Always cite specific log entries or metric values when drawing conclusions. Be concise but thorough."""

print("\nCreating Bedrock Agent...")
try:
    existing = bedrock_client.list_agents(maxResults=100)
    agent_id = None
    for ag in existing.get('agentSummaries', []):
        if ag['agentName'] == agent_name:
            agent_id = ag['agentId']
            break
            
    if not agent_id:
        response = bedrock_client.create_agent(
            agentName=agent_name,
            agentResourceRoleArn=agent_role_arn,
            foundationModel="qwen.qwen3-32b-v1:0",
            instruction=instruction
        )
        agent_id = response['agent']['agentId']
        print(f" + Agent created: {agent_id}")
        time.sleep(5)
    else:
        print(f" + Agent already exists: {agent_id}")
except Exception as e:
    print(f"Error creating agent: {e}")
    sys.exit(1)

print("\nAdding Action Groups...")
action_groups = [
    {"name": "fetch_logs", "func": "aiops-fetch-logs", "schema": "fetch_logs.json", "desc": "Search CloudWatch Logs for errors, warnings, and application events"},
    {"name": "fetch_metrics", "func": "aiops-fetch-metrics", "schema": "fetch_metrics.json", "desc": "Retrieve CloudWatch performance metrics (CPU, memory, latency, error rates)"},
    {"name": "fetch_service_health", "func": "aiops-fetch-health", "schema": "fetch_health.json", "desc": "Check live health status of EKS cluster, node groups, and crashing pods"}
]

try:
    existing_ags = bedrock_client.list_agent_action_groups(agentId=agent_id, agentVersion='DRAFT')
    existing_names = [ag['actionGroupName'] for ag in existing_ags.get('actionGroupSummaries', [])]
    
    for ag in action_groups:
        if ag['name'] in existing_names:
            print(f" + {ag['name']} (already exists)")
            continue
            
        with open(f"projects/aiops-assistant/schemas/{ag['schema']}", 'r') as f:
            schema_content = f.read()
            
        func_arn = f"arn:aws:lambda:{region}:{account_id}:function:{ag['func']}"
        bedrock_client.create_agent_action_group(
            agentId=agent_id,
            agentVersion='DRAFT',
            actionGroupName=ag['name'],
            description=ag['desc'],
            actionGroupExecutor={'lambda': func_arn},
            apiSchema={'payload': schema_content}
        )
        print(f" + {ag['name']} added")
except Exception as e:
    print(f"Error adding action groups: {e}")
    sys.exit(1)

print("\nPreparing Agent...")
bedrock_client.prepare_agent(agentId=agent_id)
print(" ✓ Agent prepared successfully")
print(f"\nYour Bedrock Agent ID is: {agent_id}")
