# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private vulnerability reporting: go to the **Security** tab of this repository and
choose **Report a vulnerability**. That opens a private advisory visible only to you and the
maintainers. If you cannot use that form, write to `support@oriveoai.com` with `SECURITY` in the
subject.

Please include what you can of:

- which client is affected (iOS, Android, web) and which version
- what an attacker can do, and what they need in order to do it
- the steps to reproduce it
- anything you already know about the fix

You will get an acknowledgement within a few days. Please give us a reasonable window to ship a fix
before disclosing publicly; we will credit you in the advisory unless you would rather we did not.

## What this project treats as a vulnerability

This is a bring-your-own-key client. Its security promises are narrow and specific, and these are
the ones worth reporting against:

- **Credential exposure.** A provider API key reaching anywhere other than the provider it belongs
  to — written to a log, included in an error report, sent to the wrong endpoint, left in an export
  that was supposed to exclude it, or readable by another app on the device.
- **Request forgery.** Anything that makes a client issue a request to a host the user did not
  configure. The relay forwarder in the web client resolves a hostname once and pins the resulting
  address for the connection, refuses loopback, private and link-local ranges, accepts only a short
  list of ports, and re-checks every redirect hop against the same rules. A way around any of that
  is a vulnerability. Two things are deliberate and are not: the address pin is applied in a
  production build, and the carrier-grade NAT range `100.64.0.0/10` is permitted on purpose, so a
  host reached over a mesh VPN stays reachable.
- **Data at rest.** Reading another storage partition's conversations or keys, or defeating the
  encryption on a password-protected backup archive.
- **Untrusted content escaping its frame.** Model output, a note, or an attachment causing code
  execution, or reaching a capability the user did not grant.
- **Supply chain.** A dependency in this repository with a known exploitable vulnerability that
  this project actually reaches.

## What is out of scope

- **Prompt injection and model behaviour.** A model that can be talked into saying something is a
  property of the model, not a defect in this client. Reports that a model produced unwanted output
  belong with that model's provider.
- **A key that a user pasted into a relay they chose to trust.** Configuring a third-party endpoint
  means giving it your key; that is the nature of the feature. A bug in *how* the key is sent is in
  scope; the decision to send it is not.
- **Cleartext HTTP to a model server on your own network.** This is deliberate and documented — a
  local engine on a private address typically has no certificate. Reaching a public host in
  cleartext would be a bug; reaching your own machine is the feature.
- **The proprietary Oriveo apps** on the App Store, Google Play, and the hosted web app. Those are a
  separate product; report issues with them through `support@oriveoai.com` rather than here.
- Missing hardening headers, or the absence of a defence, with no demonstrated impact.

## Supported versions

This project is developed on `main`, and fixes land there. There are no long-lived release branches
to backport to.
