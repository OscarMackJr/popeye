# popeye Networking — A Friendly Start-Here Guide

Version: 0.2 (junior-friendly rewrite)
For: our new network engineer — welcome!
What this is: everything you need to set up and *prove out* the network for a system called popeye, written assuming you've done networking but haven't seen our particular setup. No prior knowledge of our project assumed. If a term shows up unexplained, that's a bug in this doc — flag it and I'll fix it.

**The shape of your first few days:** read §1–§4 to understand what you're building and why (context makes the decisions obvious instead of arbitrary), then §5 is your actual to-do list, §6 is how to *test* that each piece works, and §7 is the "what does broken look like" troubleshooting table. §8 is a one-paragraph cheat sheet for your notebook.

Grab a coffee. This is friendlier than it looks.

---

## 1. What Are We Even Building? (the 30-second version)

Our company is putting all its AI usage behind one front door, so we can see what it costs, who's using it, and keep it secure. That front door is a piece of software called **popeye** — an "AI gateway."

Here's the mental model that makes everything else click. popeye is basically **a reverse proxy with a meter attached.** Every AI request in the company goes *through* it on the way to the actual AI provider (Microsoft's Azure OpenAI, and later Amazon's Bedrock). On the way through, popeye checks you're allowed, records what it cost, and logs it. That's it. Think toll booth: every car passes through, gets counted, gets charged — nobody sneaks around the side.

**Your job is the roads that lead to and from that toll booth** — the Azure network it lives in. The good news: it's a small, tidy, single-region setup. Nothing exotic.

The reason we'll be a little careful: popeye is a **chokepoint**. When it's healthy, AI works for the whole company. When its network path is broken, AI stops for the whole company. So we'd rather get the plumbing right the first time than debug it live. No pressure — that's exactly why this guide is so detailed.

---

## 2. The Codenames You'll Hear In Meetings

Our project has five parts, all with silly codenames (on purpose — it stops people assuming they know what something does from its name). **You only own the first one.** The rest are here just so you're not lost in standup.

| Name | What it is | Do you care? |
|---|---|---|
| **popeye** | The AI gateway. Its Azure network + infrastructure is your whole world. | **Yes — this is you** |
| hometown | Software that gathers business data for the AI. Runs on someone's laptop during this trial. | No |
| bluto | A service that figures out if two records are the same person. Has its own little database. | No |
| nono | An app on staff laptops that stops people sneaking around the gateway. | Only if it needs a firewall rule to *reach* the gateway |
| zt-infra | A future thing for talking to other companies. Not in this build at all. | No |

From here on, every word is about popeye.

---

## 3. What's Actually In Azure (the parts list)

Everything lives in **one resource group, one region (East US 2)**, and it's all built by Terraform (infrastructure-as-code — you change a file, not the portal; more on that in §6). Here's the whole parts list so nothing surprises you:

**The compute (what runs the gateway):**
- An **Azure Container App** — this *is* the gateway software (called LiteLLM). It listens on **port 4000**. There are **no virtual machines** anywhere — if you're hunting for a VM to SSH into, there isn't one, and that's normal. It runs at least **2 copies** ("replicas") at all times; the config literally refuses to deploy with fewer, so it stays available if one dies.
- A **Container App Environment** — think of this as the managed apartment building the app lives in. It's plugged into your network ("VNet-injected") and is **internal only** — no public front door.

**The data (what the gateway remembers):**
- **Azure Database for PostgreSQL Flexible Server** — this is the **spend ledger**: one row per AI request (who ran it, which model, how many tokens, what it cost). It's the official record of AI spending, so it's treated carefully: high-availability, backups, and **no public internet access at all** — you reach it only from inside the network. Hold onto that fact; it drives a lot of §4.
- **Azure Managed Redis** — a fast little scratchpad that tracks "how much has this user spent so far today." If it stumbles, the gateway keeps working (it just gets less strict for a moment), so it's not as precious as the ledger.

**The secrets (passwords, done properly):**
- **Two Key Vaults** — secure lockboxes. One holds the gateway's day-to-day secrets (database connection, keys). The other is a "break-glass" vault: an emergency credential that sits unused unless something goes very wrong.
- **One Managed Identity** — this is the clever bit that means **there are no passwords stored in the app anywhere.** Azure vouches for the gateway's identity directly, and we grant that identity permission to read exactly the secrets and database it needs. If you've ever hardcoded a DB password in a config file and felt bad — this is the opposite of that.

**The watching (how we know it's alive):**
- **Log Analytics + Application Insights** — where logs and metrics land.
- **Alerts** wired to a **Teams channel** — so a human gets pinged when something breaks.

**One more thing that exists but you'll rarely touch:** Terraform keeps its "current state of the world" file in an Azure Storage account, secured with Azure AD login (no keys floating around).

**What's deliberately NOT here** (so you don't waste time looking): no VMs, no public load balancer, no public IP on the database, no stored passwords. If you expected those, they're missing *on purpose*, not by accident.

---

## 4. The Network Picture — This Is The Part That's Yours

Here's the whole thing in one diagram. Everything in the big box is a **VNet** (virtual network) that *you* get to design.

```
              Internal callers (company apps, and staff laptops via nono)
                                    |
                                    |  they call in over HTTPS (:443 -> :4000)
                                    v
        +--------------------------------------------------------+
        |  VNet   <-- you assign this address space              |
        |                                                        |
        |   +-------------------------+   +------------------+    |
        |   | "containerapps" subnet  |   | "postgres" subnet|    |
        |   |  (delegated to          |   | (delegated to    |    |
        |   |   Azure Container Apps) |   |  PostgreSQL)     |    |
        |   |                         |   |                  |    |
        |   |  the gateway lives here |   |  the database    |    |
        |   |  internal LB, port 4000 |---|  lives here      |    |
        |   +-----------+-------------+   +------------------+    |
        |               |                                        |
        |               +----> Managed Redis (private)           |
        |                                                        |
        |   Private DNS zone: privatelink.postgres.database...   |
        +--------------------------------------------------------+
                                    |
                                    |  outbound only, to the AI provider
                                    v
                    Azure OpenAI / Foundry  (later, AWS Bedrock)
```

Now let me walk you through the four things in that picture that will actually matter, and *why* — because once you see the "why," the "what to do" is obvious.

### 4a. Two "delegated" subnets — and why one needs to be roomy

Two of your subnets are **delegated**, which is a specific Azure concept worth understanding: it means you hand that subnet over to an Azure service (Container Apps for one, PostgreSQL for the other) to manage internally. You still choose its address range, but you don't drop random other things into it — it belongs to that service.

**The one mistake everyone makes here:** the Container Apps subnet needs to be **generously sized.** Container Apps quietly uses up a chunk of addresses for its own internal scaling machinery. If you give it a tiny range, it works fine in the demo and then mysteriously fails to scale later. So:
- **Container Apps subnet: use a /23** (that's 512 addresses — comfortable). A /27 (32 addresses) *looks* like plenty and is the classic trap.
- **Postgres subnet: a /28 or /27 is fine** — the database doesn't need much.

### 4b. The gateway has no public door — so how do people reach it?

The gateway is set to **internal only** (in the config: `external_enabled = false`, `internal_load_balancer_enabled = true`). There is genuinely no public IP. This is a security feature: you can't attack a front door that doesn't exist.

So callers reach it **from inside the network** — either other things already running in Azure, or company/on-prem systems coming in over whatever you already use (VPN, ExpressRoute, or VNet peering).

**This is the one big decision I need to make *with* you:** how do our internal callers actually route to this internal load balancer? That depends on how our existing network is wired, which you'll know better than I do. It's the first conversation to have, not the last.

### 4c. The database hides behind a private DNS zone — and this is the #1 thing that breaks

The database has no public access. Instead it's reached through a **private DNS zone** (named something like `privatelink.postgres.database.azure.com`). Here's the part to tattoo on your hand:

> **That private DNS zone MUST be linked to the VNet, or name resolution fails and the gateway can't find its own database.**

This is, hands down, the most common "everything deployed successfully but nothing works" cause in this kind of setup. The deployment goes green, everyone celebrates, and then the gateway can't resolve the database's name because the DNS zone link is missing. We test for this explicitly in §6 — don't skip it.

### 4d. The gateway needs to call *out* to the AI provider

The gateway's whole job is talking to the AI provider, so it needs **outbound** access to the provider's endpoint (a URL ending in `.openai.azure.com`). If we have any egress filtering — a firewall, network security group rules, forced tunneling — **that endpoint has to be allowed outbound**, or every AI request dies at the final step with a timeout that *looks* like a gateway bug but is actually a firewall. Worth knowing so you don't chase the wrong thing.

---

## 5. Your Actual To-Do List (what the build is waiting on)

These are the real values and decisions the Terraform needs from you. The ones marked **⛔ REQUIRED** will literally block the deploy until they're filled in.

### 5.1 Network addresses you choose

| What | Example | Notes |
|---|---|---|
| **VNet address space** | `10.42.0.0/16` | The overall range. Must **not overlap** anything it'll connect or peer with — check our existing ranges first. |
| **Container Apps subnet** | `10.42.0.0/23` | **Size it generously (/23).** Delegated to Container Apps. This is the roomy one. |
| **Postgres subnet** | `10.42.2.0/28` | Small is fine. Delegated to PostgreSQL. |
| **How callers get in** | (a conversation) | VPN? ExpressRoute? Peering? Whatever we already use. Let's talk this one through. |

*(The example IPs are illustrative — use whatever fits our real address plan.)*

### 5.2 The internal DNS name — a small decision that saves big pain later

Right now the gateway is reachable only by an ugly auto-generated name that **changes every time the app is rebuilt** — which would silently break every app pointed at it. We want a stable, friendly name instead, something like `gateway-azure.ai.twg.internal`. This is a DNS decision, and it's yours:

- **Who owns the `ai.twg.internal` zone** (or whatever internal domain we'll use)?
- **Can we point a stable name (a CNAME/alias) at the gateway's load balancer** so it survives the app being redeployed?

Do this early. Once we pick a name, every app and every laptop agent will hardcode it, so changing it later is a company-wide chore. Picking it right the first time is a five-minute conversation now versus a migration later.

### 5.3 Provider & platform values

| What | Required? | Notes |
|---|---|---|
| **Foundry endpoint** (`https://….openai.azure.com/`) | needed to work | The AI provider URL. Must be reachable outbound (§4d). |
| **Foundry deployment name** | needed to work | Names the specific AI model and grants the gateway access. |
| **Two Key Vault names** | needed to work | Must be **globally unique across all of Azure** — so include something like the environment and region, e.g. `kv-aigw-stage2-eus2`. |
| **Teams webhook URL** | ⛔ REQUIRED | Where alerts get sent. The deploy expects it. |
| **Container image tag** | ⛔ REQUIRED | A specific version like `v1.89.x-stable`. **Never `latest`** — the deploy refuses it, on purpose (so we always know exactly what's running). |

---

## 6. Testing — How To *Prove* Each Piece Works

This is the part most guides skip, and it's the part that saves your week. Work top to bottom. For each check I've told you what a **pass** looks like *and* what a **fail** looks like, so you can tell "I set this up wrong" apart from "this isn't my problem."

You'll run most of these from a machine **inside the VNet** (a small jump box, or Azure Cloud Shell with VNet access). That "inside the network" part matters — testing from your laptop over the public internet will fail in confusing ways because there's no public door, and that failure is *expected*, not a bug.

### Check 1 — Does Terraform agree the world is set up right?

```bash
# from the popeye repo, in the env folder
terraform plan
```

- **Pass:** "No changes. Your infrastructure matches the configuration." That means what's deployed matches the code.
- **Fail:** it wants to add/change/destroy things you didn't expect → the live world has drifted from the code. Stop and ask before applying. **Never** run `terraform destroy` (see §7).

### Check 2 — Are both subnets sized and delegated correctly?

```bash
az network vnet subnet show \
  --resource-group <rg> --vnet-name <vnet> --name <containerapps-subnet> \
  --query "{prefix:addressPrefix, delegation:delegations[0].serviceName}" -o table
```

- **Pass:** the prefix is your /23 and the delegation says `Microsoft.App/environments` (Container Apps).
- **Fail — wrong delegation or empty:** the subnet isn't handed to Container Apps; the app won't deploy into it.
- **Fail — prefix smaller than /23:** it may deploy now and fail to scale later. Fix it before going further.

Repeat for the Postgres subnet (delegation should mention `Microsoft.DBforPostgreSQL/flexibleServers`).

### Check 3 — THE BIG ONE: does the private DNS zone actually resolve? *(§4c)*

First, confirm the zone is linked to the VNet:

```bash
az network private-dns link vnet list \
  --resource-group <rg> --zone-name privatelink.postgres.database.azure.com -o table
```

- **Pass:** you see a link entry pointing at your VNet, with "registration/linked" status.
- **Fail — empty list:** **this is the classic silent killer.** The zone exists but isn't linked, so nothing inside the VNet can resolve the database name. Link it before doing anything else.

Then actually resolve the name **from inside the VNet**:

```bash
nslookup <your-postgres-server-name>.postgres.database.azure.com
```

- **Pass:** it returns a **private** IP — one inside your VNet range (a `10.x` / `172.16-31.x` / `192.168.x` address).
- **Fail — returns a public IP, or doesn't resolve:** the private link/DNS isn't working. The gateway will not find its database. This is the #1 cause of "deployed but broken," so celebrate catching it here.

### Check 4 — Can we actually reach the database port, privately?

```bash
# from inside the VNet
nc -zv <your-postgres-server-name>.postgres.database.azure.com 5432
```

- **Pass:** "succeeded" / "open." The network path to Postgres works.
- **Fail — timeout:** either the DNS resolved to the wrong place (recheck Check 3) or a network security group is blocking 5432. 

### Check 5 — Is the gateway itself alive?

The gateway exposes a health endpoint on port 4000. From inside the VNet:

```bash
curl http://<gateway-internal-address>:4000/health/liveliness
```

- **Pass:** a `200 OK` with a small JSON body. The gateway is up and serving.
- **Fail — connection refused / timeout:** the app isn't running, isn't reachable on the network, or the internal load balancer isn't wired to callers yet (that's §4b — possibly the thing we still need to decide together, not a mistake on your part).

*(Heads up: Azure's own health probes hit these same endpoints. If they fail, Azure stops sending traffic to that copy of the app — so a broken probe looks exactly like an outage. Good thing to remember when something "is running but gets no traffic.")*

### Check 6 — Can the gateway reach the AI provider outbound? *(§4d)*

From inside the VNet (this tests the *egress* path the gateway depends on):

```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://<your-foundry-endpoint>.openai.azure.com/
```

- **Pass:** any HTTP response code at all (even a 401/404 is fine — it means you *reached* it; auth is the gateway's job, not the network's).
- **Fail — timeout / no route:** egress to the provider is blocked. Every AI request will fail at the last step. This points at a firewall/NSG/forced-tunnel rule that needs the provider endpoint allowed.

### Check 7 — End-to-end smoke: does a real request flow?

Once 1–6 pass, the team will run an actual AI request through the gateway and confirm a row lands in the ledger database. That's not purely a network test, so we'll do it together — but if 1–6 are green, the network side is almost certainly sound.

---

## 7. When Something's Weird — Quick Troubleshooting

| Symptom | Most likely cause | First thing to check |
|---|---|---|
| Deployed fine, gateway can't reach its database | Private DNS zone not linked to the VNet | Check 3 — the link list is probably empty |
| `nslookup` on the DB returns a public IP | Private DNS not resolving inside the VNet | Check 3 — zone link + resolve from *inside* |
| App won't scale up under load | Container Apps subnet too small | Check 2 — is it really a /23? |
| Every AI request times out at the end | Egress to the provider blocked | Check 6 — firewall/NSG allowing `*.openai.azure.com`? |
| App "is running" but gets no traffic | Health probe failing → Azure withholds traffic | Check 5 — does `/health/liveliness` return 200? |
| Testing from my laptop fails | There's no public door — by design | Test from inside the VNet, not the public internet |
| `terraform plan` wants to change things I didn't touch | Someone edited the portal directly (drift) | Don't apply — ask first |

### Two things to NEVER do
1. **Never `terraform destroy`.** The ledger database is protected for a reason — it's the official record of AI spend. (The Terraform tries to stop you, but know it anyway.)
2. **Never casually rotate the "salt key."** It invalidates every credential the gateway ever handed out. It's protected in code; just don't go poking it.

### One mindset thing
Everything is managed through Terraform, not the Azure portal. It's tempting to "just quickly fix it in the portal" — please don't, because then the code and reality disagree ("drift") and the next deploy does something surprising. Change the file, run `plan`, review, apply. Slower, but you'll never get a 2am surprise.

---

## 8. The Cheat Sheet For Your Notebook

> popeye is an internal-only Azure Container App (an AI gateway on port 4000, always ≥2 copies) that talks to a private PostgreSQL database (the spend ledger) and a private Redis (spend counters), using a managed identity so no passwords are stored anywhere. It lives in a VNet **you** design, with two delegated subnets — a roomy /23 for Container Apps, a small one for Postgres — and a private DNS zone that **must be linked to the VNet** or the database can't be found. There's no public endpoint; callers come in over the internal network. The things the build needs from you: the VNet/subnet address ranges, a decision on how internal callers route in, outbound access to the AI provider's `*.openai.azure.com` endpoint, and — do this early — a stable internal DNS name for the gateway that survives redeploys, because everything downstream will hardcode it. Test in this order: terraform plan → subnets → **private DNS resolves to a private IP** → DB port reachable → gateway `/health` returns 200 → outbound to provider works. The #1 gotcha is the private DNS zone link; check it first.

Welcome aboard — and if any of this reads as jargon-soup, that's on the doc, not on you. Ask away.
