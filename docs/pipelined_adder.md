# Running OpenROAD on the pipelined 64-bit adder

The design is `openroad_flow/designs/src/adder64_pipelined/adder64_pipelined.v`.
It adds two 64-bit numbers `CHUNK` bits at a time, over `STAGES` clock cycles,
so **`STAGES × CHUNK` must equal 64**. You will run the full flow (synthesis →
floorplan → place → CTS → route) four times:

| Run | `STAGES` | `CHUNK` | Run name (`FLOW_VARIANT`) |
|---|---|---|---|
| 1 | 2 | 32 | `stages2` |
| 2 | 8 | 8 | `stages8` |
| 3 | 16 | 4 | `stages16` |
| 4 | 64 | 1 | `stages64` |

Each run takes about **5–10 minutes** in a Codespace, except `STAGES = 64`, which
can take **15–30 minutes**.
Run them **one at a time**: the Codespace only has 2 CPUs.

## 1. Set STAGES and CHUNK

Open `openroad_flow/designs/src/adder64_pipelined/adder64_pipelined.v` and edit
the two lines near the top, for example for run 2:

```verilog
  localparam STAGES = 8;
  localparam CHUNK = 8;
```

Save the file. Only one pair of `localparam STAGES` / `localparam CHUNK` lines
should be active (not commented out).

## 2. Run the flow

From a terminal, in `openroad_flow`:

```bash
cd /workspaces/ece4203_code_2027/openroad_flow
make DESIGN=adder64_pipelined FLOW_VARIANT=stages8
make DESIGN=adder64_pipelined FLOW_VARIANT=stages8 clock_report
```

- **`FLOW_VARIANT` keeps each run in its own directory**, e.g.
  `reports/sky130hd/adder64_pipelined/stages8/`. Use a different name for every
  STAGES value, matching the table above, or the next run overwrites the last one.
- The first command runs the whole flow. It's finished when it prints a table of
  run times and returns to the prompt with no `Error`.
- The second command (`clock_report`) adds the clock tree numbers.
- If you make a mistake and want to redo a run from scratch:
  `make DESIGN=adder64_pipelined FLOW_VARIANT=stages8 clean_all`

Repeat steps 1 and 2 for all four rows of the table.

**Check that the edit took effect.** The first line of
`reports/sky130hd/adder64_pipelined/<run name>/clock_report.txt` gives the number of
flip-flops ("sinks"). It should be different for every run: about 356 for
`STAGES = 2`, 938 for 8, 1,714 for 16 and 6,370 for 64. If two runs have the same
count, you forgot to save the `.v` file before one of them.

## 3. Collect the numbers

After all four runs, collect every run's results into one spreadsheet:

```bash
make metrics
```

This writes `openroad_flow/metrics/metrics.csv`. It has one row per run, and the
`variant` column says which one (`stages2`, `stages8`, …). Right-click it in the
VS Code file explorer → **Download**, and open it in Excel. The columns you need:

| Report item | CSV column | Where it is in the run's own reports |
|---|---|---|
| Area of the layout | `die_area_um2` (µm²), and `cell_area_um2` | `logs/.../2_1_floorplan.log`, line `Die BBox` (width × height); `report_design_area` in the GUI for the cell area |
| Worst-case setup slack | `setup_ws_ns` (ns) | `reports/.../6_finish.rpt`, line `worst slack max` |
| Fastest clock speed | `fmax_mhz` (MHz) | `reports/.../6_finish.rpt`, line `period_min = … fmax = …` |
| Total clock tree delay | `clock_latency_ns` (ns) | `reports/.../clock_report.txt`, line `Latency min - max ns` (use the max) |
| Total power | `power_mw` (mW) | `reports/.../6_finish.rpt`, under `report_power`: the `Total` row, `Total Power` column (in W) |
| Clock tree power | `clock_power_mw` (mW) | `reports/.../clock_report.txt`, line `Clock power`; or the `Clock` row of `report_power` |

(`...` is `sky130hd/adder64_pipelined/stages8`, and so on for each run.)

Notes:
- **Area:** the flow sizes the die from the synthesized cell area (`CORE_UTILIZATION = 43`
  in `designs/sky130hd/adder64_pipelined/config.mk`), so each STAGES setting gets its
  own die, from about 180 × 180 µm for `STAGES = 2` to 650 × 650 µm for `STAGES = 64`.
  `die_area_um2` is the area of the whole layout. `cell_area_um2` is the area of the
  standard cells placed in it, and `utilization` is their ratio. Report both.
- **Fastest clock:** the clock constraint is 2.0 ns (500 MHz). If the slack is
  positive the design could run faster; if it's negative the design is too slow
  for 2.0 ns. Either way, the fastest clock is
  *f*<sub>max</sub> = 1 / (2.0 ns − worst slack), which is what `fmax_mhz` gives.
- **Clock tree delay** is the *insertion delay* (latency): the time from the
  `clk` pin to the clock pin of the flip-flops.

## 4. Screenshot of the final layout

Open the finished layout in the OpenROAD GUI. In the **desktop** (Ports tab →
port 6080, password `ece4203`), open a terminal and run:

```bash
cd openroad_flow     # desktop terminals start in the repo folder
make DESIGN=adder64_pipelined FLOW_VARIANT=stages8 gui_final
```

Take a screenshot of the whole die. Use the same `FLOW_VARIANT` as the run you
want to see. Things to try in the GUI:
- **Windows → Clock Tree Viewer** shows the clock tree. Click a buffer to find it in the layout.
- In the Tcl console at the bottom, `report_design_area`, `report_worst_slack` and
  `report_power` print the same numbers as in the table above.

If the GUI won't open, ORFS also saves a picture of every finished layout:
`reports/sky130hd/adder64_pipelined/stages8/final_all.webp.png`.

## 5. Summary graphs

In Excel, using `metrics.csv`, plot each of these against `STAGES`
(2, 8, 16, 64):
- fastest clock speed (`fmax_mhz`)
- area (`cell_area_um2`)
- total power (`power_mw`)

The `variant` column is text (`stages8`), so add a numeric `STAGES` column
before you plot. Use a scatter chart with lines.
