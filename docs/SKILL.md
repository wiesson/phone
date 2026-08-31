# Setting up Phone

You are setting up **Phone**, a macOS app that registers SIP lines and lets an
AI assistant answer them. This document is the whole procedure: connect to the
app, give it a line, and write the assistant that answers that line.

Work in order. Each section ends with a check — do not go on until it passes.

---

## 1. Connect to the app

Phone ships an MCP stdio server as a helper binary inside its own bundle. It
speaks JSON-RPC 2.0, MCP protocol version `2025-06-18`, and forwards every call
over a Unix socket at `~/Library/Application Support/Phone/control.sock` to the
running app.

**Phone must be running.** The helper is only a pipe; with the app closed every
tool returns `"Phone is not running."` Ask the user to launch Phone before you
continue.

Find the helper. An installed build:

```
/Applications/Phone.app/Contents/Helpers/phone-mcp
```

A build kept in the source repository:

```
<repo>/dist/Phone.app/Contents/Helpers/phone-mcp
```

Register it with your own agent runtime. For Claude Code:

```sh
claude mcp add phone -- /Applications/Phone.app/Contents/Helpers/phone-mcp
```

For Codex, add to `~/.codex/config.toml`:

```toml
[mcp_servers.phone]
command = "/Applications/Phone.app/Contents/Helpers/phone-mcp"
```

Any MCP client works — the helper needs no arguments and no environment.

**Check:** call `get_state`. You should get a state, and `registered` telling
you whether any line is currently up. Then call `list_lines` to see what already
exists. If `list_lines` returns lines, the user already has telephony; do not
create another one without asking.

---

## 2. Give the app a line

There are two ways in. Pick based on what `provisioning_status` tells you.

### 2a. Provisioned automatically (sipgate)

`provisioning_status` reports which provider can provision and whether its API
credentials are in the macOS Keychain. It returns no credential content.

If it reports credentials are **present**, you can provision without ever
handling a password:

1. `list_provisioning_endpoints` — endpoints the provider can hand out, each
   with `id`, `alias`, and `online`. The `id` is what `provision_line` takes as
   its `device_id`.
2. `provision_line` — Phone fetches the SIP credentials itself, stores the
   password in the Keychain, waits for the line to register, and returns the
   line. No secret is returned or logged.

Give `provision_line` **exactly one** of:

- `device_id` — an existing endpoint from the list, or
- `create_device: true` — plus an optional `alias` (the name at the provider).

`label` names the line inside Phone. Use something a person would recognise.

**Three things to stop and ask about first.** These reach outside the Mac and
are not yours to decide:

- `create_device: true` creates a **real endpoint on the user's provider
  account**. That may cost money.
- An endpoint reported as **online is already in use** by someone. Do not take
  it over.
- `rotate_password: true` **immediately invalidates the password of every other
  client on that endpoint** — a desk phone or softphone using it stops working
  at once. It defaults to `false`. Leave it there unless the user explicitly
  asks for a rotation, and never combine it with an endpoint you did not
  confirm is unused.

If credentials are **absent**, say so and use 2b. Nothing can be provisioned
without them.

### 2b. Entered by hand (any provider)

`create_line` takes credentials the user gives you: `username` and `password`
are required. Optional: `provider` (`telekom`, `fritzBox`, `sipgate`,
`easybell`, `custom`), `domain`, `outbound_proxy`, `stun_server`,
`media_encryption`, `label`, `sip_display_name`, `outbound_caller_id`. A known
`provider` fills in sensible defaults for the rest.

Ask the user for the password directly and pass it straight through. It is
input-only, goes into the Keychain, and is never returned — but it does travel
through your own transcript, so do not echo it back, summarise it, or write it
to a file.

**Check:** `get_registration_status`, or `list_lines` again. A working line
reports as registered. If registration fails, `create_line` returns
`registered: false` and the provider's `last_error`; fix it with `update_line`
rather than creating a second line.

---

## 3. Write the assistant

This is the part that decides whether the thing is any good. A profile has two
fields, and keeping them apart matters:

- `instructions` — **behaviour**. Who the assistant is, what it handles, where
  it stops. Changes rarely.
- `context_data` — **facts**. Hours, prices, names, menu, availability. Changes
  whenever the business does.

Mixing them means rewriting the personality to correct an opening time.

### Before you write a line

**Read the business's website, not just the brief.** Fetch the pages a caller
would ask about: services, team, hours, and whatever the business is actually
known for. If there is no website — a fictional business, say — invent the facts
deliberately and completely, and put them all in `context_data` so they are in
one place and can be corrected later.

**Read the team page and the names.** The assistant must not share a name with
an employee. Callers speak to those people afterwards, and a machine with a
colleague's name creates confusion nobody asked for. At one heating firm the
office was Melina, Andrea and Alena — both "Mia" and "Anja" were too close.

**Write down what is not known.** Prices, surcharges, opening times, funding
amounts, cancellation terms. These go into `context_data` under an explicit
heading of things never to invent. A missing answer is recoverable; an invented
surcharge is not.

### Rules every profile needs

These come from real test calls. Each one is a mistake that was actually made.

**Disclose the machine in the first sentence.** "Hier spricht X, die
KI-Telefonassistenz." When asked directly, confirm it plainly and offer a human.
The assistant never presents itself as an employee.

**Never close the conversation.** Summarise, then ask "Haben Sie sonst noch eine
Frage?" and wait. Hanging up is the caller's job. A profile ending with "Einen
schönen Tag noch" reads as being hung up on — that happened on the first real
test call, and the caller said so.

**Read names, numbers and addresses back once.** The line is telephone quality
and people call from cars and building sites. "Südring 4" came back as "Südweg
4" in a summary because nothing asked for confirmation.

**Answer "Hallo?" as a person would.** Say you are still there and repeat the
last sentence, rather than talking over a caller who cannot hear you.

**Invent nothing.** No prices, times, availability, appointments, or facts that
are the business's to decide. Say what is not known and take the question for a
callback. Put the reason in the prompt, so the model understands rather than
merely obeys: a wrong answer costs trust and money, and the caller has no way to
tell it was wrong.

**Say what the assistant does not decide.** Admission to an association, a room
at a price, an emergency callout for a non-customer. Name the criteria, take the
enquiry, and leave the decision where it belongs.

### What makes a profile good rather than merely correct

**Triage in the first two sentences.** Find out what kind of call this is, then
work the matching checklist. A short checklist per case in `context_data` beats
one long list of everything.

**Be proactive where the business is.** A hotel should ask what the stay is
meant to be like and suggest a room; a founders' association should offer the
next meetup. An assistant that only records is a worse answering machine.

**Correct the myths the business gets asked about.** This is where the value is
for a trade. A heating firm is asked whether a heat pump works in an old
building; the honest answer, from their own site, is that it depends on flow
temperature and there is a test for it. That is expertise a caller cannot get
from a web form.

**Match the register.** Founders are on first-name terms; a hotel on the coast
is warm and unhurried; a trade is calm and to the point.

### Create it

`create_assistant_profile` with `name`, `instructions`, and optional
`context_data`.

Note: repeat calls are **not** idempotent — calling it twice with the same name
creates two profiles. Call `list_assistant_profiles` first, and use
`update_assistant_profile` with the `profile_id` to change one you already made.

---

## 4. Put the assistant on the line

- `set_line_profile` — `line`, `profile` (the profile's name). This is what the
  line says when it answers.
- `set_line_answer_mode` — `line`, `mode` is `never`, `always`, or
  `outside_business_hours`; optional `answer_delay_seconds` (0–30, clamped).
- `set_line_business_hours` — `line`, plus a `weekdays` and a `weekend` window.
  Each is `{ "open": bool, "start_minute": int, "end_minute": int }` with
  minutes 0–1439 from midnight. 09:00 is `540`, 17:30 is `1050`. A window may
  cross midnight.

`set_line_prompt` sets instructions on **one line** directly, without a reusable
profile. Prefer a named profile: it can be reused, listed, and edited.

**Check:** `list_lines`. The line should show the profile name you set, and the
answer mode you chose.

---

## 5. Finish

Report to the user, in plain words:

- which line exists, at which provider, and whether it is registered
- what the assistant is called and what it will do when the phone rings
- **anything you invented** — every fact in `context_data` that you made up
  rather than read, so they can correct it before a real caller hears it
- anything you did not know and left out

Then suggest the only check that really settles it: call the number and listen
for four things. Does it disclose itself? Does it triage? Does it read back what
it heard? Does it wait at the end. Then read the summary and compare every
number in it against what was actually said.

Both times a profile went live, the first real call found something no amount of
reading had.

---

## Tool reference

Read-only, safe to call at any time:
`get_state` · `list_lines` · `get_registration_status` · `provisioning_status` ·
`list_provisioning_endpoints` · `list_assistant_profiles` · `get_history` ·
`get_last_summary` · `get_transcript` · `find_contact`

Change saved configuration:
`create_line` · `update_line` · `delete_line` · `select_active_line` ·
`set_line_enabled` · `set_line_profile` · `set_line_prompt` ·
`set_line_answer_mode` · `set_line_business_hours` ·
`create_assistant_profile` · `update_assistant_profile` ·
`delete_assistant_profile`

Reach the outside world — confirm with the user first:
`provision_line` (the provider account) · `dial` · `assistant_call` · `answer` ·
`hangup` · `send_dtmf` (the telephone network)
