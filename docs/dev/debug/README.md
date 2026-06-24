# Debug Reports

Root-cause analyses for tricky bugs encountered during Poste development.

## Index

| Report | Date | Symptom | Root Cause |
|--------|------|---------|------------|
| [stale-header-float.md](stale-header-float.md) | 2026-06 | USE leaves old SELECT column heads in dataset panel | Float window handle (`float_win`) becomes stale; `nvim_win_is_valid` returns false but window still visible |