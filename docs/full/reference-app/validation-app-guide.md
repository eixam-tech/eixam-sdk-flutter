# Validation App Guide

The control app is a thin validation host for the SDK.

## What it is for

- bootstrapping SDK instances for internal validation
- switching backend/environment config in controlled internal flows
- rendering diagnostics and operational state
- manually validating device, SOS and Protection Mode behavior

## What it is not

- the final partner product UX
- the owner of safety business logic
- the public integration contract

## Internal bootstrap note

The validation app may use internal factory/bootstrap composition for debug flexibility. That does not replace the public partner bootstrap path documented in the partner site.
