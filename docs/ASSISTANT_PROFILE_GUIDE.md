# Writing an assistant profile

A profile is what the assistant is on one line: who it says it is, what it
handles, and where it stops. Everything here comes from profiles that were
written and then heard on a real call — the mistakes are ones that were actually
made, not ones that were imagined.

A profile has two parts. `instructions` is behaviour, `contextData` is facts.
Keep them apart: behaviour rarely changes, facts change whenever the business
does, and mixing them means rewriting the personality to fix an opening time.

## Before writing a line

**Read the website, not the brief.** The audit says what to sell; the website
says what the assistant has to know. Fetch the pages a caller would ask about:
services, team, opening hours, and whatever the business is actually known for.

**Fetch the team page and read the names.** The assistant must not be called
what an employee is called. Callers speak to those people afterwards, and a
machine that shares a name with the receptionist creates a confusion nobody
asked for. At one heating firm the customer service office was Melina, Andrea
and Alena — "Mia" and "Anja" were both too close.

**Write down what you do not know.** Prices, surcharges, opening times, funding
amounts, cancellation terms. These end up in `contextData` under an explicit
heading of things never to invent. A missing answer is recoverable; a made-up
surcharge is not.

## Rules every profile needs

**Disclose the machine, first sentence.** "Hier spricht X, die KI-Telefon­
assistenz." And when asked directly, confirm it plainly and offer a human. The
assistant never presents itself as an employee.

**Never close the conversation.** Summarise, then ask "Haben Sie sonst noch eine
Frage?" and wait. Hanging up is the caller's job. A profile that ends with
"Einen schönen Tag noch" reads as being hung up on — that is exactly what
happened on the first real test call, and the caller said so.

**Read names, numbers and addresses back once.** The line is telephone quality
and callers ring from cars and building sites. "Südring 4" came back as
"Südweg 4" in a summary because nothing asked for confirmation.

**Answer "Hallo?" as a person would.** Say you are still there and repeat the
last sentence, rather than continuing into a caller who cannot hear you.

**Invent nothing.** No prices, times, availability, appointments, or facts that
are the business's to decide. Say what is not known and take the question for a
callback. The reason belongs in the prompt so the model understands rather than
merely obeys — a wrong answer costs trust and money, and the caller has no way
to tell it was wrong.

**Say what the assistant does not decide.** Admission to an association, a room
at a price, an emergency callout for a non-customer. Name the criteria, take the
enquiry, and leave the decision where it belongs.

## What makes a profile good rather than correct

**Triage in the first two sentences.** Find out what kind of call this is and
work the matching list. A checklist per case in `contextData` beats one long
list of everything.

**Be proactive where the business is.** A startup association should suggest the
next open meetup; a hotel should ask what the stay is meant to be like. An
assistant that only records is a worse answering machine.

**Correct the myths the business is asked about.** This is where the value is
for a trade. A heating firm gets asked whether a heat pump works in an old
building; the honest answer, taken from their own website, is that it depends on
flow temperature, and there is a test for it. That is expertise the caller
cannot get from a form.

**Match the register.** An association of founders is on first-name terms; a
hotel on the coast is warm and unhurried; a trade is calm and to the point.

## Checking it

Call the line and listen for four things: does it disclose itself, does it
triage, does it read back what it heard, and does it wait at the end. Then read
the summary and compare every number in it against what was actually said.

Both times a profile went live, the first real call found something no amount of
reading had.
