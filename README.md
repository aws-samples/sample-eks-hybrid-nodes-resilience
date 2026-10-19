# Amazon EKS Hybrid Nodes: On-Premises Resilience and GPU Cloud Bursting

CloudFormation templates, Kubernetes manifests and lab assets for extending an Amazon EKS cluster
into a simulated on-premises data center, proving workloads survive network failures and control
plane disconnection, and bursting inference capacity to cloud GPUs with Karpenter.

**Amazon EKS Hybrid Nodes · Site-to-Site VPN · Transit Gateway · Hyper-V nested virtualization · Cilium · Karpenter · AWS FIS**

> **This is sample code, for non-production usage.** You should work with your security and legal
> teams to meet your organizational security, regulatory and compliance requirements before
> deployment. The environment ships **demo-grade defaults** that are deliberate teaching choices,
> not recommendations: read [Security and Hardening](#security-and-hardening) before you reuse any
> of it.

### There is a workshop that walks through this code

This repository is the **code**. The guided, step-by-step content lives in a separate workshop,
*Amazon EKS Hybrid Nodes: On-Premises Resilience and GPU Cloud Bursting*, which walks the modules
in order and explains the reasoning behind each step. This repository is what its self-paced route
clones and deploys.

## Table of Contents

- [Overview](#overview)
- [What You Will Build](#what-you-will-build)
- [Repository Structure](#repository-structure)
- [Getting Started](#getting-started)
- [Cost](#cost)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)
- [Known Limitations](#known-limitations)
- [Security and Hardening](#security-and-hardening)
- [Third-party components](#third-party-components)
- [Contributing](#contributing)
- [License](#license)

## Overview

Three questions every hybrid Kubernetes team asks, answered hands-on:

1. **Can I manage on-premises capacity with the same control plane I use in the cloud?**
   Yes: you join on-premises nodes to EKS with `nodeadm` and SSM hybrid activations. One cluster,
   one API, two locations.
2. **What happens to my workloads when the link to AWS goes down?**
   They keep serving. You inject real faults with AWS FIS (data path) and a surgical control plane
   block, then watch an AI inference service answer requests from a fully isolated data center.
   NotReady is not down.
3. **What do I do when demand outgrows my data center?**
   Burst. The cluster runs Karpenter, and the same deployment overflows to automatically
   provisioned cloud nodes, including GPUs (`g6`) for a model the on-premises hardware could never
   serve.

The demo workload is **LLM inference** (Ollama): a small quantized model on CPU as the resilient
on-premises baseline, and a larger model on cloud GPU as the elastic burst tier.

Everything runs in a single AWS account, in a single Region.

## What You Will Build

![EKS Hybrid Nodes lab architecture: an EKS control plane in AWS connected over Transit Gateway and Site-to-Site VPN to a simulated data center, where an EC2 Hyper-V host runs two Ubuntu VMs as hybrid nodes; inside the EKS VPC, the Hybrid Nodes Gateway runs Cilium VTEP on two EC2 cloud nodes and builds a VXLAN tunnel so cloud pods reach on-premises pods](docs/images/lab-architecture.png)

*Figure 1: One EKS control plane extended into a simulated data center over Site-to-Site VPN and
Transit Gateway.*

Five CloudFormation stacks, deployed in order. Each one publishes SSM parameters under
`/workshop/eks-hybrid/` that the next one reads.

| # | Stack | Template | Creates |
|---|---|---|---|
| 1 | `eks-hybrid-network-bootstrap` | `eks-hybrid-network-bootstrap.yaml` | The EKS VPC (`10.42.0.0/16`) and its two subnets |
| 2 | `eks-hybrid-cluster` | `eks-hybrid-cluster.yaml` | The EKS cluster `eks-hybrid-workshop` (Kubernetes 1.36) with remote node network `10.80.0.0/16` and remote pod network `10.85.0.0/16`, a baseline node group (`t4g.xlarge`), the Hybrid Nodes gateway node group (2 x `t3.large`), Amazon Managed Service for Prometheus, and the CodeBuild project that builds the inference images into two ECR repositories in your account |
| 3 | `eks-hybrid-datacenter` | `eks-hybrid-datacenter.yaml` | The simulated data center VPC (`10.90.0.0/16`), the Transit Gateway, the Site-to-Site VPN to a Libreswan appliance (`t3.small`), and the AWS FIS experiment template |
| 4 | `eks-hybrid-code-editor` | `eks-hybrid-code-editor.yaml` | The browser IDE: code-server `4.131.0` on a `t3.medium` in the data center DMZ subnet, behind CloudFront, provisioned by SSM State Manager. It bootstraps the cluster and seeds `~/workshop` from your assets bucket |
| 5 | `eks-hybrid-hyperv-host` | `eks-hybrid-hyperv-host.yaml` | The on-premises host: an `m8i.4xlarge` running Windows Server and Hyper-V with nested virtualization, and two Ubuntu 24.04 VMs. `hybrid-node-1` (`10.80.1.11`) joins the cluster during provisioning, `hybrid-node-2` (`10.80.1.12`) is left for you to join |

When it finishes you have: an EKS cluster with `remoteNetworkConfig`, a VPC, Transit Gateway and
Site-to-Site VPN acting as the WAN, a Hyper-V host with two hybrid node VMs (one already joined),
FIS experiment templates, Cilium, Karpenter NodePools, KEDA, MetalLB, the inference images built
into your account's ECR, and a browser IDE in the data center's DMZ subnet, which is why your
terminal survives the WAN outage in the resilience module.

## Repository Structure

```text
.
├── infrastructure/cloudformation/        The five stacks, in deploy order
│   ├── eks-hybrid-network-bootstrap.yaml     1. EKS VPC and subnets
│   ├── eks-hybrid-cluster.yaml               2. EKS cluster, node groups, AMP, image build
│   ├── eks-hybrid-datacenter.yaml            3. Data center VPC, Transit Gateway, VPN, FIS
│   ├── eks-hybrid-code-editor.yaml           4. Browser IDE (code-server) behind CloudFront
│   └── eks-hybrid-hyperv-host.yaml           5. Hyper-V host and the two hybrid node VMs
│
├── assets/workshop/                      Participant assets, seeded into ~/workshop in the IDE
│   ├── manifests/                            Inference, monitoring and image pre-pull manifests
│   ├── dashboards/hybrid-nodes.json          Grafana dashboard for the on-premises tier
│   ├── scripts/preflight-check.sh            Environment check run from the IDE
│   └── seeds/                                cloud-init seeds for the two Ubuntu VMs
│
├── scripts/
│   └── upload-workshop-assets.sh         Publishes assets/workshop/ to your assets bucket
│
└── docs/images/lab-architecture.png      Figure 1
```

## Getting Started

### Prerequisites

| Requirement | Notes |
|---|---|
| AWS account | A **dedicated, non-production account** with no other workloads or data, see [Security and Hardening](#security-and-hardening). `AdministratorAccess` or equivalent: the templates create named IAM roles |
| Workstation | bash 3.2+ on macOS or Linux, or AWS CloudShell. Windows is not tested |
| AWS CLI v2 | Configured with credentials for the target account |
| Git and `curl` | To clone this repository |
| Region | `us-east-1` is the tested Region, see [Known Limitations](#known-limitations) |

### Service quotas

| Quota | Code | Minimum | Recommended | Where the number comes from |
|---|---|---|---|---|
| Running On-Demand Standard instances (vCPU) | `L-1216C47A` | 44 | 48 | 28 vCPU in steady state (Hyper-V host `m8i.4xlarge` 16, baseline `t4g.xlarge` 4, gateway 2 x `t3.large` 4, VPN appliance `t3.small` 2, IDE `t3.medium` 2) plus the 16 vCPU ceiling of the `cpu-burst-od` NodePool. The recommended 48 adds 4 for the baseline node group replacing its node (`MaxSize: 2`) |
| All Standard Spot Instance Requests (vCPU) | `L-34B43A08` | - | 48 | Only for the Spot burst pool of the GPU cloud bursting module |
| Running On-Demand G and VT instances (vCPU) | `L-DB2E81BA` | 4 | 8 | Only to run the GPU page hands-on. The `gpu-burst` NodePool accepts `g6.xlarge` (4 vCPU), `g6.2xlarge` (8) and `g6.4xlarge` (16), and the GPU pod fits a `g6.xlarge`. 8 covers Karpenter falling back to a `g6.2xlarge` |

Check what you have (read-only):

```bash
for q in L-1216C47A L-34B43A08 L-DB2E81BA; do
  aws service-quotas get-service-quota --service-code ec2 --quota-code "$q" \
    --query 'Quota.[QuotaCode,QuotaName,Value]' --output text --region "${AWS_REGION:-us-east-1}"
done
```

A new account usually starts below these numbers. Request increases in the Service Quotas console
before you deploy: the G quota in particular is measured in vCPUs and can take hours to days.

### 1. Clone the repository

`WORKSHOP_NAME` is fixed: all five stacks read `/workshop/eks-hybrid/` hardcoded, so do not change
it. It is passed explicitly to every stack so the five stay aligned if a template default ever
drifts.

```bash
git clone https://github.com/aws-samples/sample-eks-hybrid-nodes-resilience.git
cd sample-eks-hybrid-nodes-resilience
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export WORKSHOP_NAME=eks-hybrid
```

### 2. Create the assets bucket and publish the assets

The IDE seeds `~/workshop` from this bucket, the Hyper-V host reads the VM cloud-init seeds from
it, and the CLI stages the templates in it. Keep this exact name: the workshop's validation and
cleanup steps derive it the same way.

```bash
export ASSETS_BUCKET="eks-hybrid-workshop-assets-${ACCOUNT_ID}"
aws s3api create-bucket --bucket "$ASSETS_BUCKET"
./scripts/upload-workshop-assets.sh "$ASSETS_BUCKET" "$AWS_REGION"
aws s3 ls "s3://$ASSETS_BUCKET/workshop/" --recursive | wc -l
```

The last command prints `12`. The script checks the 12 files before it calls AWS, refuses a bucket
with a public policy, and asserts the size (and, under SSE-S3, the MD5) of every object it
uploaded, ending with `OK: 12/12 objects verified`.

> `create-bucket` in `us-east-1` needs no location constraint. In any other Region add
> `--create-bucket-configuration LocationConstraint=$AWS_REGION`.

> **Upload before stack 4.** Without the assets, the IDE skips seeding silently: the stack still
> reaches `CREATE_COMPLETE`, and `~/workshop` is empty. The Hyper-V host fails at `CreateVMs`
> without the seeds.

### 3. Deploy the network, cluster and data center stacks

`--s3-bucket` is on every deploy: two of the five templates exceed the 51,200-byte limit
CloudFormation accepts inline, and one uniform command removes that class of error.

```bash
aws cloudformation deploy \
  --stack-name eks-hybrid-network-bootstrap \
  --template-file infrastructure/cloudformation/eks-hybrid-network-bootstrap.yaml \
  --s3-bucket "$ASSETS_BUCKET" --s3-prefix cfn \
  --parameter-overrides WorkshopName="${WORKSHOP_NAME}" \
  --capabilities CAPABILITY_NAMED_IAM
```

```bash
aws cloudformation deploy \
  --stack-name eks-hybrid-cluster \
  --template-file infrastructure/cloudformation/eks-hybrid-cluster.yaml \
  --s3-bucket "$ASSETS_BUCKET" --s3-prefix cfn \
  --parameter-overrides WorkshopName="${WORKSHOP_NAME}" \
  --capabilities CAPABILITY_NAMED_IAM
```

```bash
aws cloudformation deploy \
  --stack-name eks-hybrid-datacenter \
  --template-file infrastructure/cloudformation/eks-hybrid-datacenter.yaml \
  --s3-bucket "$ASSETS_BUCKET" --s3-prefix cfn \
  --parameter-overrides WorkshopName="${WORKSHOP_NAME}" \
  --capabilities CAPABILITY_NAMED_IAM
```

### 4. Deploy the IDE stack

The IDE lives in the **data center's** DMZ subnet, not in the EKS VPC: that is why your terminal
survives the WAN outage. The template defaults to the data center already; the overrides keep it
explicit. `AssetsBucketPrefix` is deliberately empty because the script uploaded to the root of
your bucket; an AWS-hosted event fills it with its own prefix.

```bash
aws cloudformation deploy \
  --stack-name eks-hybrid-code-editor \
  --template-file infrastructure/cloudformation/eks-hybrid-code-editor.yaml \
  --s3-bucket "$ASSETS_BUCKET" --s3-prefix cfn \
  --parameter-overrides \
      WorkshopName="${WORKSHOP_NAME}" \
      VPCId=/workshop/eks-hybrid/dc-vpc-id \
      PublicSubnetId=/workshop/eks-hybrid/dc-dmz-subnet \
      AssetsBucketName="${ASSETS_BUCKET}" \
      AssetsBucketPrefix= \
  --capabilities CAPABILITY_NAMED_IAM
```

Build the one-click IDE sign-in link. The stack output `IdeUrl` is only the address; the sign-in
token lives in Secrets Manager, so reading stack outputs is not enough to open the IDE:

```bash
IDE_URL=$(aws cloudformation describe-stacks --stack-name eks-hybrid-code-editor \
  --query "Stacks[0].Outputs[?OutputKey=='IdeUrl'].OutputValue" --output text)
IDE_TOKEN=$(aws secretsmanager get-secret-value --secret-id /eks-hybrid/ide-password \
  --query SecretString --output text)
echo "${IDE_URL}?tkn=${IDE_TOKEN}"
```

Open the printed link. It signs you in with one click, so treat it as a secret. The stack completes
before code-server finishes installing, because setup runs through SSM State Manager: if the page
does not load, wait two to three minutes and refresh.

### 5. Wait for the IDE key, then deploy the Hyper-V host

Stack 5 bakes the IDE's SSH public key into the VMs' cloud-init, and the IDE publishes that key from
a State Manager association that runs **after** stack 4 completes. Wait for it:

```bash
until aws ssm get-parameter --name /workshop/eks-hybrid/ide-ssh-pubkey >/dev/null 2>&1; do
  echo "waiting for the IDE to publish its SSH public key..."; sleep 30
done
echo "key published - safe to deploy stack 5"
```

If you are redeploying into an account that already ran this, run [Cleanup](#cleanup) first: a key
left by a previous IDE makes this loop pass at once, and the VMs get the wrong key.

`AssetsBucket` is required on this template; it reads the VM seeds from there.

```bash
aws cloudformation deploy \
  --stack-name eks-hybrid-hyperv-host \
  --template-file infrastructure/cloudformation/eks-hybrid-hyperv-host.yaml \
  --s3-bucket "$ASSETS_BUCKET" --s3-prefix cfn \
  --parameter-overrides \
      WorkshopName="${WORKSHOP_NAME}" \
      AssetsBucket="${ASSETS_BUCKET}" \
  --capabilities CAPABILITY_NAMED_IAM
```

The stack reaches `CREATE_COMPLETE` only after the VMs are built and `hybrid-node-1` has joined,
through a `WaitCondition` that allows up to 90 minutes. The CLI waiter gives up after 60 minutes
while the stack keeps creating; if that happens, follow it with
`aws cloudformation describe-stacks --stack-name eks-hybrid-hyperv-host --query 'Stacks[0].StackStatus'`.

### 6. Verify, from a terminal inside the IDE

Open the sign-in link from step 4, then in the IDE terminal:

```bash
ls ~/workshop
find ~/workshop -type f | wc -l
```

The first prints `dashboards  manifests  scripts  seeds`, the second `12`.

```bash
source ~/workshop-env.sh && kubectl get nodes
```

Three cloud nodes and one hybrid node (`mi-*`), all `Ready`.

```bash
source ~/workshop-env.sh && ~/workshop/scripts/preflight-check.sh
```

Every line `[ OK ]`, except the GPU line, which is `[ -- ]` until quota `L-DB2E81BA` is at least 4
vCPUs. A failing line names the missing prerequisite: return to the matching step above, or see
[Troubleshooting](#troubleshooting). Where the script says to call your facilitator, that wording is
for AWS-hosted events; self-paced, Troubleshooting is the place.

From here the workshop content is identical to an AWS-hosted event. Only provisioning and
[cleanup](#cleanup) differ.

## Cost

Cost is driven by resources that bill per hour whether or not you are using them. List prices for
`us-east-1`, On-Demand, read from the AWS Price List on 2026-10-14:

| Component | Quantity | USD per hour |
|---|---|---|
| Hyper-V host `m8i.4xlarge`, Windows Server (license included) | 1 | 1.5827 |
| Cloud nodes: baseline `t4g.xlarge` and gateway `t3.large` | 1 + 2 | 0.3008 |
| VPN appliance `t3.small` and IDE `t3.medium` | 2 | 0.0624 |
| EKS control plane (standard support) | 1 | 0.1000 |
| Transit Gateway attachments (VPC and VPN) | 2 | 0.1000 |
| Site-to-Site VPN connection | 1 | 0.0500 |
| Public IPv4 addresses (3 cloud nodes, VPN appliance, IDE) | 5 | 0.0250 |
| EBS gp3: 300 GB at 250 MiB/s on the host, 30 GB IDE, 3 x 20 GB nodes, 8 GB appliance | - | 0.0505 |
| **Idle total** | | **about 2.27** |

That is **about USD 2.27 per hour**, or **about USD 1,660 per month if you forget to delete it**
(730 hours). A four-hour run costs about USD 9 at that rate, plus the deploy time before you start
and the usage-based items below.

Not in the total, because they depend on usage: Amazon Managed Service for Prometheus ingestion,
CloudWatch Logs, ECR storage of the two inference images, the one CodeBuild image build, CloudFront
requests, three Secrets Manager secrets, two customer managed KMS keys (USD 1 per key-month,
prorated by the hour), and the burst nodes of the GPU cloud bursting module (a
`g6.xlarge` is USD 0.8048 per hour, and it is On-Demand by design, so it does not go away on its
own). Check the [AWS Pricing Calculator](https://calculator.aws/) for your Region and date.

The single most effective cost control is running [Cleanup](#cleanup) when you finish.

## Cleanup

Run it from your **workstation**, not from the IDE: deleting stack 4 deletes the IDE, and the
terminal goes with it. The only step that runs in the IDE is the first one.

```text
1. In the IDE: delete the workloads, so Karpenter reclaims its nodes
2. Delete stacks 5, 4 and 3, retrying the VPN and Transit Gateway delete
3. Release Karpenter's instance profiles immediately before deleting stack 2
4. Delete stack 1
5. What CloudFormation does not own: hybrid registrations, log groups, the IDE's SSM parameter, the assets bucket
6. Verify nothing survived
```

**1. In the IDE terminal:**

```bash
kubectl delete -f ~/workshop/manifests/inference-gpu.yaml --ignore-not-found
kubectl delete -f ~/workshop/manifests/inference-burstable.yaml --ignore-not-found
kubectl delete -f ~/workshop/manifests/inference-onprem.yaml --ignore-not-found
kubectl delete -f ~/workshop/manifests/inference-service-lb.yaml --ignore-not-found
kubectl delete -f ~/workshop/manifests/onprem-monitoring.yaml --ignore-not-found
kubectl get nodeclaims
```

Wait until `kubectl get nodeclaims` returns nothing: a NodeClaim holds an EC2 instance you pay for.

**2. From your workstation, stacks 5, 4 and 3.** The VPN resource can report deleted before its
Transit Gateway attachment finishes, which fails the first delete of the data center stack with
`non-deleted VPN Attachments`. A minute later the retry succeeds.

```bash
for STACK in eks-hybrid-hyperv-host eks-hybrid-code-editor eks-hybrid-datacenter; do
  if ! aws cloudformation describe-stacks --stack-name "$STACK" >/dev/null 2>&1; then
    echo "$STACK not present - skipping"; continue
  fi
  for attempt in 1 2 3; do
    echo "deleting $STACK (attempt $attempt) ..."
    aws cloudformation delete-stack --stack-name "$STACK"
    if aws cloudformation wait stack-delete-complete --stack-name "$STACK" 2>/dev/null; then
      echo "  $STACK gone"; break
    fi
    echo "  $STACK delete did not converge; waiting 60s before retry"
    sleep 60
  done
done
```

**3. Stack 2, and the Karpenter trap.** Karpenter creates one instance profile per `EC2NodeClass`
and does not remove them. They hold the node role, so the cluster delete fails with
`Cannot delete entity, must remove roles from instance profile first`. Releasing them early does
not work: the controller runs until the cluster is gone and recreates them. Release them
**immediately** before the delete, and again if it fails:

```bash
release_profiles () {
  local role
  role=$(aws cloudformation describe-stack-resources --stack-name eks-hybrid-cluster \
    --logical-resource-id NodeRole --query 'StackResources[0].PhysicalResourceId' \
    --output text 2>/dev/null)
  if [ -z "$role" ] || [ "$role" = "None" ]; then
    return 0
  fi
  for p in $(aws iam list-instance-profiles-for-role --role-name "$role" \
      --query 'InstanceProfiles[].InstanceProfileName' --output text); do
    case "$p" in
      eks-hybrid-workshop_*)
        echo "  releasing Karpenter profile $p"
        aws iam remove-role-from-instance-profile --instance-profile-name "$p" --role-name "$role"
        aws iam delete-instance-profile --instance-profile-name "$p" ;;
      *) echo "  keeping non-Karpenter profile $p" ;;
    esac
  done
}

if aws cloudformation describe-stacks --stack-name eks-hybrid-cluster >/dev/null 2>&1; then
  for attempt in 1 2 3; do
    echo "cluster delete, attempt $attempt"
    release_profiles
    aws cloudformation delete-stack --stack-name eks-hybrid-cluster
    if aws cloudformation wait stack-delete-complete --stack-name eks-hybrid-cluster 2>/dev/null; then
      echo "  cluster gone"; break
    fi
    echo "  delete failed - Karpenter had probably recreated a profile. Retrying."
  done
fi
```

**4. Stack 1:**

```bash
if aws cloudformation describe-stacks --stack-name eks-hybrid-network-bootstrap >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name eks-hybrid-network-bootstrap
  aws cloudformation wait stack-delete-complete --stack-name eks-hybrid-network-bootstrap
  echo "network gone"
fi
```

**5. What CloudFormation does not own.** The SSM managed-instance records and activations of the
hybrid nodes, the log groups Lambda, CodeBuild and Container Insights create, the SSH key parameter
the IDE published with `put-parameter`, and your assets bucket. These commands remove only names
this sample creates:

```bash
for MI in $(aws ssm describe-instance-information \
    --filters Key=ResourceType,Values=ManagedInstance \
    --query 'InstanceInformationList[?starts_with(ComputerName,`hybrid-node-`)].InstanceId' \
    --output text); do
  aws ssm deregister-managed-instance --instance-id "$MI"
done

for A in $(aws ssm describe-activations \
    --query 'ActivationList[?starts_with(DefaultInstanceName,`eks-hybrid-node`)].ActivationId' \
    --output text); do
  aws ssm delete-activation --activation-id "$A"
done

for G in $(aws logs describe-log-groups \
    --query 'logGroups[?starts_with(logGroupName,`/aws/lambda/eks-hybrid`) || starts_with(logGroupName,`/aws/codebuild/eks-hybrid`) || starts_with(logGroupName,`/aws/containerinsights/eks-hybrid`)].logGroupName' \
    --output text); do
  aws logs delete-log-group --log-group-name "$G"
done

for P in $(aws ssm describe-parameters \
    --query 'Parameters[?starts_with(Name,`/workshop/eks-hybrid/`)].Name' --output text); do
  aws ssm delete-parameter --name "$P" && echo "deleted $P"
done

ASSETS_BUCKET="eks-hybrid-workshop-assets-$(aws sts get-caller-identity --query Account --output text)"
if aws s3api head-bucket --bucket "$ASSETS_BUCKET" >/dev/null 2>&1; then
  aws s3 rb "s3://${ASSETS_BUCKET}" --force
fi
```

These prefixes are this sample's names. In an account you also use for other things, read the
lists before you delete.

**6. Verify:**

```bash
aws cloudformation list-stacks \
  --query 'StackSummaries[?starts_with(StackName,`eks-hybrid`) && StackStatus!=`DELETE_COMPLETE`].[StackName,StackStatus]' \
  --output table

aws ec2 describe-vpn-connections \
  --query 'VpnConnections[?State!=`deleted`].[VpnConnectionId,State]' --output table

aws ec2 describe-transit-gateways \
  --query 'TransitGateways[?State!=`deleted`].[TransitGatewayId,State]' --output table
```

Empty tables are the goal. The ECR repositories delete with the cluster stack (`EmptyOnDelete`), and
the SSM output bucket of stack 4 is emptied by a custom resource on delete. The two customer managed
KMS keys (Kubernetes Secrets in stack 2, the RDP credential in stack 5) are scheduled for deletion
with their stacks: they stay listed as `PendingDeletion` for 7 days, then KMS deletes them. The
CloudFront access log group of stack 4 is deleted with that stack. Give
billing a day to settle, then check Cost Explorer in the Region you deployed into.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Templates with a size greater than 51,200 bytes must be deployed via an S3 Bucket` | `aws cloudformation deploy` ran without `--s3-bucket`, and two templates exceed the inline limit | Add `--s3-bucket "$ASSETS_BUCKET" --s3-prefix cfn` to the command |
| `aws cloudformation deploy` for stack 5 stops with a waiter timeout | The CLI waiter gives up after 60 minutes; the stack's `WaitCondition` allows 90 | The stack keeps creating. Follow it with `aws cloudformation describe-stacks --stack-name eks-hybrid-hyperv-host --query 'Stacks[0].StackStatus'` |
| The Step 5 loop is still waiting after ~15 minutes | The IDE's State Manager association is failing rather than running slowly, so it never publishes `ide-ssh-pubkey` | Read the execution history of the `SetupAssociationId` output of stack 4: `aws ssm describe-association-executions --association-id <SetupAssociationId>`. Stack 5 cannot succeed until the key exists |
| `~/workshop` is empty in the IDE | Stack 4 was deployed without `AssetsBucketName`, or before the upload | Redeploy stack 4 with `AssetsBucketName="${ASSETS_BUCKET}" AssetsBucketPrefix=`. If the parameter was right and only the upload came late, run `./scripts/upload-workshop-assets.sh` and then `aws ssm start-associations-once --association-ids <SetupAssociationId>` |
| Hyper-V automation fails with `seed user-data-N is X bytes` | A cloud-init seed in the bucket is truncated; the host rejects seeds under 200 bytes | Re-run `./scripts/upload-workshop-assets.sh "$ASSETS_BUCKET" "$AWS_REGION"` (it refuses a seed under 200 bytes before uploading), delete the Hyper-V stack, and deploy it again |
| All five stacks complete, but the VMs never build, with `SSM param ide-ssh-pubkey not published after 10 min` | The stacks were deployed with different `WorkshopName` values, so the IDE published its key where the Hyper-V host does not look | Deploy all five with `WorkshopName=eks-hybrid` |
| Hyper-V host fails with `base image not usable after 15 minutes (...) - check s3://<ArtifactBucket>/hyperv/ubuntu-24.04-base.vhdx and the IDE prepareHypervImage step` | The second artifact stack 5 needs from the IDE, the Ubuntu base image, is not ready. The Step 5 loop only waits for the SSH key | Check the `prepareHypervImage` step in the execution history of the `SetupAssociationId` association (`aws ssm describe-association-executions`, then `describe-association-execution-targets` for the latest execution). Once it succeeds, the Hyper-V automation retries on its own 30-minute association. If the stack already rolled back, delete it, wait for `DELETE_COMPLETE`, and run Step 5 again |
| `InsufficientInstanceCapacity` for `m8i.4xlarge` | The Hyper-V host runs in the Availability Zone at index 1 of the Region (`!Select [1, !GetAZs '']`), and that zone has no capacity or does not offer the type | Check `aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=m8i.4xlarge`. Retry later, or use another supported Region |
| `VcpuLimitExceeded` | The Standard On-Demand vCPU quota is below what the stacks need | Raise `L-1216C47A` to at least 44 (48 recommended), see [Service quotas](#service-quotas) |
| The preflight reports `Inference images missing from your account's ECR`, or the inference pods sit in `ImagePullBackOff` | The `eks-hybrid-images` CodeBuild build is still running or failed, and there is no fallback registry. The usual failure is Docker Hub's anonymous pull rate limit (100 pulls per 6 hours per source address, and CodeBuild hosts share addresses): the build log shows `toomanyrequests: You have reached your pull rate limit. You may increase the limit by authenticating and upgrading: https://www.docker.com/increase-rate-limits`, then `=== BASE IMAGE PULL FAILED for docker.io/ollama/ollama@sha256:7e67...` | From your workstation: `aws codebuild batch-get-builds --ids "$(aws codebuild list-builds-for-project --project-name eks-hybrid-images --query 'ids[0]' --output text)" --query 'builds[0].buildStatus'`, and `aws logs filter-log-events --log-group-name /aws/codebuild/eks-hybrid-images --filter-pattern '"pull rate limit"' --query 'events[].message'`. If it failed, wait for the limit window and run `aws codebuild start-build --project-name eks-hybrid-images`. The manifests already point at your ECR, so the pods retry on their own |
| Step 5 loop passes at once on a redeploy, and the VMs reject the IDE's SSH key | `ide-ssh-pubkey` survives the stack deletes; only Cleanup removes it, so the loop saw the previous IDE's key | Run [Cleanup](#cleanup) before redeploying into the same account |

## Known Limitations

| Limitation | Detail |
|---|---|
| `WorkshopName` is fixed at `eks-hybrid` | Every stack reads `/workshop/eks-hybrid/` hardcoded. Another value passes the deploy and fails about 30 minutes later |
| One deployment per account | The cluster name `eks-hybrid-workshop`, the IAM role `eks-hybrid-nodes-role` and the CloudFront Function `eks-hybrid-ide-edge-auth` are fixed names, and IAM and CloudFront names are global to the account |
| `us-east-1` is the only tested Region | `us-east-2` and `us-west-2` are supported by the templates (the CloudFront prefix list map and the `m8i.4xlarge` zone placement) but not tested. Outside the Regions in the prefix list map the IDE stack fails at `FindInMap`. Outside `us-east-1` the IDE stack creates no CloudFront access logs, because CloudFront log delivery can only be configured in `us-east-1` |
| The CLI waiter is shorter than stack 5 | 60 minutes against a 90-minute `WaitCondition`, see [Troubleshooting](#troubleshooting) |
| The GPU page needs a G quota | Hands-on only with `L-DB2E81BA` at 4 vCPUs or more. Without it, the CPU burst tier still runs the rest of the bursting module |
| Assets must be published before stack 4 | The IDE copies from the bucket, not from your clone. After changing anything under `assets/workshop/`, re-run the upload script |

## Security and Hardening

This environment is built to **teach**, in a disposable account, for the length of a workshop. Some
of its defaults would be defects in production. They are listed here rather than silently fixed,
because each one exists to make a lesson visible.

**Deploy it into a dedicated, non-production account.** In an AWS-hosted event the account is
destroyed when the event ends. When you run it self-paced in your own account, **nothing is
destroyed automatically**: every endpoint below stays reachable until you run [Cleanup](#cleanup).

While the stacks exist, these endpoints are reachable from the internet:

| Endpoint | Protocol | Access control |
|---|---|---|
| IDE CloudFront distribution (`IdeUrl`) | HTTPS to CloudFront, then HTTP on port 8080 to the instance | The sign-in token (Secrets Manager `/eks-hybrid/ide-password`) arrives once as `?tkn=`, and the edge moves it into an HttpOnly cookie. nginx on the instance checks that cookie against the token and requires an origin secret header that only this distribution adds (`/eks-hybrid/ide-password-origin`). Without a cookie the edge answers 403; with a wrong one, or without the origin header, nginx answers 401 or 403. The instance security group admits only the CloudFront origin-facing prefix list |
| EKS API server endpoint | HTTPS | IAM authentication. The endpoint is public, with no CIDR restriction |
| Libreswan VPN appliance | UDP 500 and 4500 from `0.0.0.0/0` | IPsec with the two AWS VPN tunnel endpoints |

| Default | Why it is like that | Before you reuse it |
|---|---|---|
| The IDE sign-in link is a **bearer credential**: whoever holds the token holds the IDE, and the token does not expire (the cookie lasts 12 hours) | You reach a working IDE in one click, with no account setup. The token is kept out of stack outputs and out of the CloudFront Function code, so read-only access to the account (`DescribeStacks`, `GetFunction`) does not reveal it; reading it takes `secretsmanager:GetSecretValue` on that secret. The hop from CloudFront to the instance is plain HTTP inside AWS, so the cookie and the origin header cross it unencrypted. To rotate the token: `aws secretsmanager put-secret-value --secret-id /eks-hybrid/ide-password --secret-string "$(openssl rand -hex 16)"`, then `aws ssm start-associations-once --association-ids <SetupAssociationId>` | Put a real identity provider in front of it, terminate TLS on the origin (or use a CloudFront VPC origin to a private subnet), and delete the stack when you finish |
| The IDE instance role operates the lab: cluster admin on **this** cluster through an EKS access entry, the two drill documents of module 5 on the hybrid nodes, the FIS templates tagged `workshop=eks-hybrid`, the `/workshop/eks-hybrid/` parameters, the workshop's own secrets, and `iam:PassRole` for `eks-hybrid-nodes-role` to Systems Manager only. What remains account-wide: read and list calls (EC2, CloudFormation, IAM roles, SSM, ECR), and `ssm:CreateActivation`, `ssm:AddTagsToResource` and `ssm:DeleteActivation`, which take no resource scope | You operate the cluster, run fault injection and register hybrid nodes from the IDE terminal. Anyone holding an IDE session holds this role | Remove the activation calls and FIS outside a lab, and keep the role to what your own exercises need |
| The IDE bootstrap gives **cluster admin** to the account's console roles it finds by name (`WSParticipantRole`, `admin`, `Admin`, and `AWSReservedSSO_AdministratorAccess*`), and restores those access entries every 30 minutes | Without it, the EKS console shows an access error on the Nodes tab of a self-paced deploy | Grant console access explicitly with your own access entry, and remove the discovery loop from the `clusterBootstrap` step |
| The on-premises host is **Windows Server with nested virtualization** on `m8i.4xlarge`. Its RDP credentials are generated into Secrets Manager (`/eks-hybrid/hyperv-rdp-credentials`, encrypted with a customer managed key) and the IDE token and origin secret too (`/eks-hybrid/ide-password*`, AWS managed key); **none rotates on its own** | Hyper-V on EC2 is what makes the data center real enough to fail; the secrets live only as long as the stacks | Rotate, or avoid long-lived passwords and use Session Manager or Fleet Manager |
| EBS: the IDE, Hyper-V host and VPN appliance volumes are encrypted explicitly; the managed node groups and the Karpenter burst nodes use the account default. IMDSv2 is required everywhere, with a hop limit of 1 on the IDE and the Hyper-V host | The node volumes follow the AMI and Karpenter defaults that the lab inspects | Turn on EBS encryption by default for the account and Region (`aws ec2 enable-ebs-encryption-by-default`) before you deploy |
| The EKS endpoint is **public** | Hybrid nodes must reach the Kubernetes API from outside the VPC, and the resilience module depends on the control plane staying reachable from on-premises during a VPC-path outage | Private endpoint plus a resolver path from the data center, and `publicAccessCidrs` restricted to your ranges if public access stays |
| UDP 500 and 4500 open to `0.0.0.0/0` on the VPN appliance | The AWS VPN tunnel outside IPs are known only after the connection exists, so the template cannot scope them | Narrow the rules to the two tunnel outside IPs once the VPN exists |
| Data center security groups allow **all protocols** (`-1`) between private CIDRs | They simulate a flat data center LAN, the environment hybrid nodes actually run in. Every rule is scoped to a private CIDR, never `0.0.0.0/0` | Segment the network and allow only what hybrid nodes need: 443 to the EKS endpoint and AWS APIs, 10250 from the VPC for kubelet, and the CNI overlay ports |
| **Public subnets** with auto-assigned public IPs and a route to an internet gateway, in the EKS VPC and the data center DMZ | The DMZ needs a routable address for the IPsec tunnel, and the simulated site needs its own internet egress, as a real site has | Private subnets with NAT for anything that does not terminate a tunnel; keep only the customer gateway appliance in the DMZ |
| The SSM output bucket of stack 4 uses **SSE-S3 (not KMS)**, with versioning and a 7-day lifecycle, but no object lock and no TLS-only bucket policy | It holds transient provisioning artifacts for the life of the stacks | SSE-KMS with a customer managed key, a policy that denies requests without TLS, and object lock where retention matters |
| ECR repositories use the **AWS managed KMS key** and basic scan on push, but nothing blocks an image with findings; the CodeBuild project runs in **privileged mode** without an explicit KMS key | The build runs `docker build` once at provisioning, to bake the inference images into your account | Enforce a policy that blocks critical findings, use a customer managed key, set a CMK on the project, and build outside privileged mode where you can |
| Lambda custom resources run **outside a VPC, without a DLQ** or reserved concurrency | They run a handful of times during create and delete, calling only AWS APIs | In a persistent stack, VPC-attach anything that touches private resources and add a DLQ |
| CloudFront uses the **default certificate**; its access logs go to the CloudWatch Logs log group `eks-hybrid-ide-cloudfront-access` for **7 days**, **without the query string, the cookies or the referer** | There is no custom domain in a lab account, and with the default certificate CloudFront does not let you raise the minimum viewer TLS version. The sign-in token travels in the query string once and then in a cookie, so those fields are left out of the log on purpose; the log group is deleted with the stack. nginx on the instance also logs every request, without the query string | An ACM certificate on your own domain with a TLS 1.2 minimum viewer policy, and a retention period that matches your own policy |
| Kubernetes Secrets are envelope-encrypted with a customer managed key, but the EKS **control plane logs** and VPC Flow Logs are off | The lab does not read them, and they would outlive the stacks as log groups | Enable `api`, `audit` and `authenticator` logging and Flow Logs with a retention period |
| **Third-party software is downloaded at run time** from its official upstreams: code-server, the IDE CLI tools (pinned, sha256-checked), Helm charts and container images, the Ollama base image from Docker Hub (pinned by digest), and the Llama models from `registry.ollama.ai` during the image build. The inference images are built in your account and pulled only from your account's ECR; there is no fallback registry | It keeps the sample free of vendored binaries and models, and the in-account images are what lets a disconnected site still start its pods | Mirror what you depend on into your own registry, pin every image by digest, and authenticate the Docker Hub pulls of the build to avoid the anonymous rate limit |

None of this is a substitute for your own review. Run your own scanners and threat model against
anything you carry from here into an account that matters.

If you discover a potential security issue, follow the process in
[CONTRIBUTING.md](CONTRIBUTING.md#security-issue-notifications) rather than opening a public issue.

## Third-party components

Everything below is installed **at run time from its own upstream registry**. This repository
redistributes none of it.

**The Llama models.** Deploying stack 2 downloads Meta's Llama 3.2 1B and Llama 3.1 8B into your
account (the image build pulls them from `registry.ollama.ai`; this repository and its templates
carry no model weights). By deploying, you accept the
[Llama 3.2 Community License](https://github.com/meta-llama/llama-models/blob/main/models/llama3_2/LICENSE)
and the [Llama 3.1 Community License](https://github.com/meta-llama/llama-models/blob/main/models/llama3_1/LICENSE),
and their Acceptable Use Policies
([3.2](https://github.com/meta-llama/llama-models/blob/main/models/llama3_2/USE_POLICY.md),
[3.1](https://github.com/meta-llama/llama-models/blob/main/models/llama3_1/USE_POLICY.md)).
Review them with your legal team before you deploy.

| Component | Purpose | Upstream | License | Note |
|---|---|---|---|---|
| Cilium (Amazon EKS distribution) | CNI on the hybrid nodes, VXLAN datapath for the gateway | `public.ecr.aws/eks/cilium/cilium` | `Apache-2.0` | |
| Amazon EKS Hybrid Nodes gateway | Pod reachability from the VPC into the data center | `public.ecr.aws/eks/eks-hybrid-nodes-gateway` | `Apache-2.0` | |
| Karpenter | Node autoscaling for the cloud burst tier | `public.ecr.aws/karpenter/karpenter` | `Apache-2.0` | |
| KEDA | Event-driven pod autoscaling | `kedacore/keda` Helm chart | `Apache-2.0` | |
| MetalLB | On-premises LoadBalancer VIPs | `metallb/metallb` Helm chart | `Apache-2.0` | |
| Prometheus, kube-state-metrics, blackbox_exporter | Local metrics tier that survives disconnection | prometheus-community | `Apache-2.0` | |
| Grafana | Local dashboards read during the outage | grafana/grafana | `AGPL-3.0` | Unmodified upstream image, run as-is. Only the dashboard JSON is authored here |
| Ollama | The inference server | `ollama/ollama` (Docker Hub) | `MIT` | Version 0.5.7, pinned by digest. The base of the two images the build creates in your account |
| Llama 3.2 1B (`llama3.2:1b`) | The on-premises and CPU burst model | registry.ollama.ai | `LicenseRef-Llama-3.2` | Llama 3.2 Community License. Pulled into your account by the image build |
| Llama 3.1 8B (`llama3.1:8b`) | The GPU burst model | registry.ollama.ai | `LicenseRef-Llama-3.1` | Llama 3.1 Community License. Pulled into your account by the image build |
| code-server | The browser IDE | coder/code-server | `MIT` | |
| Libreswan | IPsec on the simulated customer gateway appliance | libreswan.org | `GPL-2.0` | Unmodified distribution package |
| nginx, busybox | Throwaway probe images in validation steps | Docker Official Images | `BSD-2-Clause`, `GPL-2.0` | |
| Ubuntu 24.04, Amazon Linux 2023, Windows Server | Guest and host operating systems | Canonical, AWS, Microsoft | Vendor terms | |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Please open an issue before submitting substantial changes.

## License

Licensed under the **MIT-0** licence (MIT No Attribution). See [LICENSE](LICENSE) and
[NOTICE](NOTICE).
