# Fencing EC2 nodes with sushy-tools and FAR

FAR (Fence Agents Remediation) fences a sick node by talking to its BMC. AWS
gives you no BMC. This makes each EC2 instance *look like* it has one:

```
FAR  ->  fence_redfish  ->  sushy-tools (speaks Redfish)  ->  AWS driver  ->  EC2 API
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

This repo holds the deployment side: the FAR template, the IAM policy, and
the runbook below — including timings measured against real EC2, which is
the part you cannot get from documentation.

Only power control is implemented, because that is all a fence agent asks
for. Everything here was run end to end on a real OpenShift cluster on
2026-09-30; that cluster has since been destroyed.

---

## 1. Where to run the emulator

**Not on a node it might be asked to fence.** It would kill itself part-way
through the operation. A small separate instance is simplest.

It must be reachable over the network from the FAR pod, since that is where
the fence agent actually runs.

## 2. Credentials

Attach an IAM role to the emulator's instance and let `boto3` pick it up. Do
not put keys in the emulator config or in any command line — the driver never
reads credentials from its own config, by design.

`iam-policy.json` holds the minimal policy. It allows power control only on
instances tagged `rhwa-lab=true`; change the tag to match your lab. Note that
`ec2:DescribeInstances` cannot be restricted by resource tag — AWS does not
support resource-level permissions for it — so it is granted on `*`.

## 3. Install and run

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
reboot — what FAR does by default — should be budgeted at roughly 40 s worst
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
time $FR -o reboot     # off, poll, on -- the path FAR actually takes
```

All five must exit 0.

**If `off` takes more than ~20 seconds**, the agent's default
`--power-timeout` of 20 is too short. `far-redfish-aws-template.yaml` already
sets it to 60; adjust it to what you measured, and keep the CR's `timeout`
comfortably above the off + on total, since both happen in a single agent run.

Useful cross-check against the raw API, to separate driver latency from EC2
latency:

```bash
time aws ec2 stop-instances --instance-ids $IID --force --skip-os-shutdown
```

## 5. Wire up FAR

```bash
oc apply -f far-redfish-aws-template.yaml
```

Fill in `<EMULATOR-IP>` and the node-to-instance mapping first. Get the
mapping from each node's `providerID`, which embeds the instance ID:

```bash
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'
# worker-0    aws:///us-east-1a/i-0123456789abcdef0
```

The per-node `--systems-uri` is not optional: `fence_redfish` discovers
systems by listing `/redfish/v1/Systems` and taking the **last** entry, so
without it every node would fence whichever instance happens to sort last.

The FAR template controller validates a template by running
`fence_redfish --action status` for each node listed, so a wrong instance ID
or an unreachable emulator shows up as soon as you apply it, not at fencing
time.

## 6. Fence a node for real

Create a FenceAgentsRemediation CR named after the node — that is how FAR
picks its target. `far-cr-example.yaml` is a worked example; edit the node
name and instance ID, then:

```bash
oc apply -f far-cr-example.yaml
oc get far -n openshift-workload-availability -w
oc get nodes -w
```

In normal operation you would not create this by hand — NHC creates it for
you when a node goes unhealthy. Doing it manually is just the quickest way
to prove the path works.

### Result, 2026-09-30

Fenced one worker on a 3-master/3-worker OpenShift cluster in `us-west-2`.
It worked end to end:

```
Processing=False                 RemediationFinishedSuccessfully
FenceAgentActionSucceeded=True   FenceAgentSucceeded
Succeeded=True                   RemediationFinishedSuccessfully
```

The emulator log shows exactly the sequence `fence_redfish` is supposed to
produce for a reboot, and nothing else:

```
10:45:29  POST .../ComputerSystem.Reset   204   <- ForceOff
10:45:30  GET  .../Systems/i-0123...      200   <- poll, ~1/s
   ...    (14 seconds of polling)
10:45:43  POST .../ComputerSystem.Reset   204   <- On
```

Off phase took 14 s that run, inside the 11–30 s range measured above.
FAR then applied `node.kubernetes.io/out-of-service:NoExecute`, pod count on
the node dropped 27 → 13 (only DaemonSets and static pods left), the
`image-registry` Deployment pod rescheduled onto another worker, and zero
pods were left Pending cluster-wide. No cluster operator went Degraded. The
node returned to `Ready` about 5 minutes after the reboot.

Deleting the FAR CR afterwards removes the out-of-service taint and puts the
node back in service.

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
