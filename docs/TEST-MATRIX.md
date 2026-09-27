# Test matrix — RESTOR-PC Boot Manager

| Feature | Offline | VHD | Physical | CI | Status |
| --- | --- | --- | --- | --- | --- |
| Manifest parser / integrity engine | yes | yes | no | yes | covered |
| Restore dry-run | yes | mocked | no | yes | covered |
| Restore Apply + post-restore hashes | mocked | real VHDX | no | partial (offline only) | covered |
| Double backup integrity gate | yes | yes | no | yes | covered |
| Full blank-disk rebuild | mocked guards | real VHDX lab | no | no-hosted | covered locally |
| Recovery media staging | yes | no | no | yes | covered |
| Recovery media WinPE ISO | optional | no | no | no | backend-dependent |
| Release integrity manifest | yes | no | no | yes | covered |
| Physical NVMe boot menu | manual | no | historical | no | not re-run in v1.3.0 labs |
| Clear-Disk / diskpart clean absence | AST | AST | n/a | yes | enforced |

Notes :

- GitHub Actions exécute `Test-Repository.ps1` (offline). Tags `VHD` exclus.
- Aucun test ne cible le NVMe `SAMSUNG MZVLB256HAHQ-000L2`.
- Ne pas prétendre qu'un scénario physique non exécuté a été validé.
