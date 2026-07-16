# Feature Specifications

This directory contains the executable specification for this project,
written using **EARS** (Easy Approach to Requirements Syntax) and
**Gherkin**.

## Why EARS + Gherkin?

Requirements written in natural language are often ambiguous, untestable,
and disconnected from the code that implements them. EARS and Gherkin solve
this by giving requirements a precise structure that is both human-readable
and machine-executable.

**EARS** provides sentence templates for requirements. Each requirement
follows a pattern like:

> *When* \<trigger\>, *the system shall* \<response\>.

This eliminates vague language and forces every requirement to state exactly
one testable behavior. The six EARS patterns (ubiquitous, event-driven,
state-driven, optional-feature, unwanted-behavior, and complex) cover
virtually all requirement types while keeping the syntax simple enough for
non-technical stakeholders to read and validate.

**Gherkin** turns each requirement into concrete, executable scenarios
written in Given/When/Then form. These scenarios serve three purposes
simultaneously:

1. **Living documentation** -- they describe the system's behavior in plain
   language that anyone on the team can read.
2. **Acceptance criteria** -- they define exactly what "done" means for each
   requirement.
3. **Automated tests** -- they execute against the real system through step
   definitions, ensuring the documentation never drifts from reality.

## How this directory is organized

```text
features/
  NNNN-short-name.feature   Feature files containing EARS requirements and scenarios
  step_definitions/
    given/                   Step definitions for preconditions
    when/                    Step definitions for actions/events
    then/                    Step definitions for expected outcomes
    support/                 Shared helpers and fixtures
  dashboard.html             Interactive spec browser (open in any browser)
  README.md                  This file
```

Each `.feature` file groups related requirements under a single `Feature:`
heading. Within a file, each EARS requirement is a `Rule:` block whose title
*is* the requirement. Scenarios underneath a Rule verify that the
requirement holds.

Step definitions live in one-file-per-step form, organized by keyword
(`given/`, `when/`, `then/`). This keeps steps easy to find, reuse, and
audit.

## Browsing the specification

Open [`dashboard.html`](dashboard.html) in a browser for an interactive view
of all feature files and their step definitions. The dashboard:

- Parses `.feature` files and renders them as a searchable, collapsible tree
- Matches each scenario step to its step definition file
- Lets you click through to view step definition source with syntax
  highlighting

To use it, open the file and select this project's root directory (or this
`features/` directory) when prompted.

## Auditing

The audit script checks both specification quality and step definition
hygiene:

```bash
python <path-to-ears-gherkin-dev-skill>/scripts/audit.py features/
```

It catches common problems like vague language in requirements, missing step
definitions, duplicate steps, and naming inconsistencies. Run it after every
change to the specification.
