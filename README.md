# Redfish power control for EC2 instances

EC2 gives you no BMC. This makes each instance *look like* it has one, so
anything that speaks Redfish can power it on and off:

```
Redfish client  ->  sushy-tools (speaks Redfish)  ->  AWS driver  ->  EC2 API
```

The driver is an addition to upstream
[sushy-tools](https://opendev.org/openstack/sushy-tools), on the
`aws-systems-driver` branch of
<https://github.com/RanWurmbrand/sushy-tools>:

| File | What |
|---|---|
| `sushy_tools/emulator/resources/systems/awsdriver.py` | the driver |
| `sushy_tools/tests/unit/emulator/resources/systems/test_aws.py` | unit tests |
| `sushy_tools/emulator/main.py` | `--aws` / `--aws-region` wiring |
| `doc/source/user/dynamic-emulator.rst` | user docs |

This repo holds the deployment side: how to run the emulator, a minimal IAM
policy, and the runbook below — including timings measured against real
EC2, which is the part you cannot get from documentation.

**Only power control is implemented.** No virtual media, BIOS, storage or
boot device selection. That is enough for a fence agent, and not enough to
provision a machine.

> Want automated node fencing on OpenShift with NHC and FAR? That sits on
> top of this and lives on the
> [`far-fencing`](https://github.com/RanWurmbrand/sushy-aws-fencing/tree/far-fencing)
> branch: operator subscriptions, a FenceAgentsRemediationTemplate, and a
> recorded end-to-end fence of a real node.

---

## 0. Quick path

To run the emulator inside an OpenShift cluster on AWS:

```bash
AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
  CLUSTER_TAG=kubernetes.io/cluster/<infra-id>=owned REGION=us-east-1 \
  ./deploy/build-and-deploy.sh
```

Your infra ID comes from `oc get infrastructure cluster -o
jsonpath='{.status.infrastructureName}'`. `CLUSTER_TAG` is just a filter —
any tag works; it decides which instances are exposed as Redfish systems.

To run it on a plain host instead, see section 3.

## 1. Where to run the emulator

**Not on a machine it might be asked to power off.** It would kill itself
part-way through the operation.

`deploy/10-emulator.yaml` runs it in the cluster pinned to a control-plane
node, so as long as you only ever power-cycle workers it is safe. A separate
EC2 instance outside the cluster works too and survives cluster rebuilds.

Either way it has to be reachable from whatever will be making the Redfish
calls.

## 2. Credentials

The driver never reads credentials from its own config, by design — `boto3`
resolves them. On a standalone EC2 instance, attach an IAM role and nothing
else is needed. In-cluster there is no instance role to borrow, so
`build-and-deploy.sh` puts an access key in a Secret; use a dedicated IAM
user for it, not your own.

`iam-policy.json` holds the minimal policy. It allows power control only on
instances carrying a given tag — change the tag to match your cluster, e.g.
`kubernetes.io/cluster/<infra-id>: owned`. Note that `ec2:DescribeInstances`
cannot be restricted by resource tag — AWS does not support resource-level
permissions for it — so it is granted on `*`.

## 3. Running it standalone

`deploy/build-and-deploy.sh` covers the in-cluster case. To run it on a
plain host instead:

```bash
git clone -b aws-systems-driver https://github.com/RanWurmbrand/sushy-tools
cd sushy-tools
pip install -e . 'boto3>=1.39.12'

sushy-emulator \
  --aws --aws-region us-east-1 \
  --ssl-certificate /etc/sushy/cert.pem \
  --ssl-key /etc/sushy/key.pem \
  -i 0.0.0.0 -p 8000
```

To expose only the lab's instances, put this in a config file and pass
`--config`:

```python
SUSHY_EMULATOR_AWS_DRIVER = True
SUSHY_EMULATOR_AWS_REGION = 'us-east-1'
SUSHY_EMULATOR_AWS_TAG = 'rhwa-lab=true'
```

A self-signed certificate is fine for a lab, paired with `--ssl-insecure` on
the agent side.

## 4. Check it by hand, and time the power-off

This is step 5 of the plan, and the one open question worth answering: **how
long a force-stop actually takes.** AWS documents no duration for a stop with
`SkipOsShutdown`.

### Measured, 2026-09-30

An `m6i.xlarge` worker in `us-west-2`, real `fence_redfish` against the
driver against real EC2:

| Operation | Samples | Range |
|---|---|---|
| `-o off` | 4 | **11, 19, 22, 30 s** |
| `-o on` | 4 | 8, 9, 9, 9 s |
| `-o reboot` (off + on) | 1 | 26 s |

**A force-stop is slow and very variable — up to 30 s.** The fence agent's
default `--power-timeout` of 20 would have failed two of those four runs, so
**setting `--power-timeout` is required, not optional.** The template uses
`60`, which leaves good headroom over the worst case observed.

Powering on is quick and consistent, so the off phase dominates. A full
reboot — off then on — should be budgeted at roughly 40 s worst
case, comfortably inside the template's `timeout: 120s` for a single agent
run.

Re-measure if you change instance type or region; these numbers are one
instance type in one region on one afternoon.

```bash
EMU=<emulator-ip>
IID=i-0123456789abcdef0
FR="fence_redfish --ip=$EMU --ssl-insecure --systems-uri=/redfish/v1/Systems/$IID"

$FR -o status          # expect: Status: ON
time $FR -o off        # <-- record this; expect: Success: Powered OFF
$FR -o status          # expect: Status: OFF
time $FR -o on         # expect: Success: Powered ON
time $FR -o reboot     # off, poll, on -- what a fencing reboot does
```

All five must exit 0.

**If `off` takes more than ~20 seconds**, the agent's default
`--power-timeout` of 20 is too short. Pass a larger value; 60 leaves
headroom over the worst case measured here.

Useful cross-check against the raw API, to separate driver latency from EC2
latency:

```bash
time aws ec2 stop-instances --instance-ids $IID --force --skip-os-shutdown
```

---

## Things worth knowing

**A stopping instance reports `On`, not `Off`.** Only EC2's `stopped` state
maps to `Off`. The fence agent treats `Off` as proof the machine is dead; an
instance in `stopping` is still running and may still be writing to storage.

**`Force=True` alone does not cut the instance off.** `StopInstances` still
attempts a graceful OS shutdown first and only forces it after a timeout. The
driver therefore sends `SkipOsShutdown=True` as well, which needs
`botocore>=1.39.12`. With anything older the driver logs a warning and falls
back to `Force` alone — it still works, but it waits on the guest OS, which
is exactly what fencing must not do. Check for that warning in the emulator
log after the first force-off.

**Public IPs change across a stop/start; instance IDs and private IPs do
not.** Cluster nodes must talk to each other over private addresses, and the
`--systems-uri` mapping is stable because it uses instance IDs.

**A terminated instance reports no power state at all**, rather than `Off`.
It is gone, not merely powered down, and a power request against one is
rejected rather than silently ignored.
