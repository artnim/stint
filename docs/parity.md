# Parity check against a reference implementation

`ParityTests` compares the PDF Stint renders for one month with a PDF produced
independently from the same data (a Python script that reads the same solidtime export
through its API). It is skipped unless three environment variables point at the inputs.

1. Export the month from solidtime as a **detailed** CSV, or generate an equivalent file
   from the API (the import reads Description, Project, Client, Start, End, Duration, Break
   and Tags).
2. Produce the reference PDF for the same month with the reference implementation, using
   the same rounding (15-minute grid, durations rounded up, starts snapped up, English).
3. Run the gate:

       cd TimeCore
       PARITY_CSV=~/Downloads/export-2026-09.csv \
       PARITY_PDF=~/Downloads/reference-2026-09.pdf \
       PARITY_MONTH=2026-09 swift test --filter ParityTests

Green means every entry's hours and time range, every day row, the entry count and the
total match. Run it for at least two months, one of them containing a DST change, before
relying on the output.
