# Beta Evidence Archive

This directory stores install beta checklist evidence.

Structure:
- `history/<run_id>/` archived outputs for each checklist run
- `latest` symlink to the most recent run

`run_id` format:
- `beta-checklist-YYYYMMDD-HHMMSS`

Minimal archived files per run:
- `summary.json`
- `A.install.out`
- `B.verify.out`
- `C.upgrade.out`
- `D.flow.out`
- `D.env.out`
