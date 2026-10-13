# Parity check against solidtime_report.py

Before retiring the Python script, prove the Swift report gives the same numbers.

1. In solidtime, export the month as a **detailed** CSV (Reports → Export → CSV detailed).
2. Produce the reference PDF with the wrapper, which uses the API path:
       cd ~/Projects/solidtime-report && ./leistungsnachweis.sh 2026-09
3. Run the gate:
       cd TimeCore
       PARITY_CSV=~/Downloads/solidtime_2026-09.csv \
       PARITY_PDF=~/Projects/solidtime-report/Timesheet_2026-09.pdf \
       PARITY_MONTH=2026-09 swift test --filter ParityTests

Green means every entry's hours, every day row and the total match. Do this for the
reference month in the solidtime-report README (70 entries, 140.00 h) and for the latest
month before switching the monthly run over.
