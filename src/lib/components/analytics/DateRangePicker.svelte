<script lang="ts">
  import CalendarIcon from '@lucide/svelte/icons/calendar';
  import ChevronLeftIcon from '@lucide/svelte/icons/chevron-left';
  import ChevronRightIcon from '@lucide/svelte/icons/chevron-right';

  let {
    startDate = $bindable(''),
    endDate   = $bindable(''),
  }: { startDate: string; endDate: string } = $props();

  let open = $state(false);
  // Temp values while picker is open (applied on click Apply)
  let tempStart = $state(startDate);
  let tempEnd   = $state(endDate);
  // Which month each calendar panel is showing
  let leftYear  = $state(0);
  let leftMonth = $state(0); // 0-based
  let selecting = $state<'start' | 'end'>('start');
  let hovered   = $state('');

  const MONTHS = ['January','February','March','April','May','June',
                  'July','August','September','October','November','December'];
  const PRESETS = [
    { label: 'Today',        fn: () => today() },
    { label: 'Yesterday',    fn: () => yesterday() },
    { label: 'Last 7 days',  fn: () => lastN(7) },
    { label: 'Last 30 days', fn: () => lastN(30) },
    { label: 'Last 90 days', fn: () => lastN(90) },
    { label: 'Last 12 months', fn: () => allTime() },
    { label: 'All time',     fn: () => allTime() },
  ];

  function fmt(d: Date) {
    return d.toISOString().slice(0, 10);
  }
  function applyPreset(s: string, e: string) {
    startDate = s; endDate = e;
    tempStart = s; tempEnd = e;
    open = false;
  }
  function today() {
    const d = fmt(new Date()); applyPreset(d, d);
  }
  function yesterday() {
    const d = new Date(); d.setDate(d.getDate() - 1);
    const s = fmt(d); applyPreset(s, s);
  }
  function lastN(n: number) {
    const end = new Date();
    const start = new Date(); start.setDate(start.getDate() - n + 1);
    applyPreset(fmt(start), fmt(end));
  }
  function allTime() {
    applyPreset('2025-09-30', '2025-11-12');
  }

  function openPicker() {
    tempStart = startDate;
    tempEnd   = endDate;
    const ref = tempStart || fmt(new Date());
    leftYear  = parseInt(ref.slice(0, 4));
    leftMonth = parseInt(ref.slice(5, 7)) - 1;
    open = true;
    selecting = 'start';
  }

  function apply() {
    startDate = tempStart;
    endDate   = tempEnd;
    open = false;
  }

  function cancel() {
    open = false;
  }

  function prevMonth() {
    if (leftMonth === 0) { leftMonth = 11; leftYear--; }
    else leftMonth--;
  }
  function nextMonth() {
    if (leftMonth === 11) { leftMonth = 0; leftYear++; }
    else leftMonth++;
  }

  // Returns array of {date, inMonth} for a calendar grid
  function calDays(year: number, month: number) {
    const first = new Date(year, month, 1).getDay(); // 0=Sun
    const days = new Date(year, month + 1, 0).getDate();
    const cells: Array<{ d: string; out: boolean }> = [];
    // Previous month fill
    for (let i = 0; i < first; i++) {
      const d = new Date(year, month, 1 - (first - i));
      cells.push({ d: fmt(d), out: true });
    }
    for (let i = 1; i <= days; i++) {
      cells.push({ d: fmt(new Date(year, month, i)), out: false });
    }
    // Next month fill to complete grid
    while (cells.length % 7 !== 0) {
      const d = new Date(year, month + 1, cells.length - days - first + 1);
      cells.push({ d: fmt(d), out: true });
    }
    return cells;
  }

  const leftDays  = $derived(calDays(leftYear, leftMonth));
  const rightYear = $derived(leftMonth === 11 ? leftYear + 1 : leftYear);
  const rightMonth = $derived(leftMonth === 11 ? 0 : leftMonth + 1);
  const rightDays = $derived(calDays(rightYear, rightMonth));

  function clickDay(d: string) {
    if (selecting === 'start') {
      tempStart = d;
      tempEnd   = '';
      selecting = 'end';
    } else {
      if (d < tempStart) {
        tempEnd   = tempStart;
        tempStart = d;
      } else {
        tempEnd = d;
      }
      selecting = 'start';
    }
  }

  function inRange(d: string) {
    const s = tempStart, e = tempEnd || hovered;
    if (!s) return false;
    const lo = s < e ? s : e;
    const hi = s < e ? e : s;
    return d > lo && d < hi;
  }
  function isStart(d: string) { return d === tempStart; }
  function isEnd(d: string)   { return d === (tempEnd || (selecting === 'end' ? hovered : '')); }

  const displayLabel = $derived(() => {
    if (!startDate && !endDate) return 'Select date range';
    if (startDate === endDate) return fmtDisplay(startDate);
    return `${fmtDisplay(startDate)} – ${fmtDisplay(endDate)}`;
  });

  function fmtDisplay(d: string) {
    if (!d) return '';
    const dt = new Date(d + 'T00:00:00');
    return dt.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
  }
</script>

<!-- Trigger -->
<button class="drp-trigger" onclick={openPicker}>
  <CalendarIcon class="size-3.5" />
  {displayLabel()}
</button>

<!-- Popover -->
{#if open}
  <!-- Backdrop -->
  <div class="drp-backdrop" onclick={cancel}></div>

  <div class="drp-popover">
    <!-- Presets -->
    <div class="drp-presets">
      {#each PRESETS as p}
        <button
          class="drp-preset {tempStart === (p.label === 'All time' ? '2025-11-11' : '') ? 'active' : ''}"
          onclick={p.fn}
        >{p.label}</button>
      {/each}
    </div>

    <!-- Calendars -->
    <div class="drp-right">
      <div class="drp-inputs">
        <div class="drp-input-wrap">
          <label>Start</label>
          <input type="date" bind:value={tempStart} onchange={() => selecting = 'end'} />
        </div>
        <span class="drp-dash">–</span>
        <div class="drp-input-wrap">
          <label>End</label>
          <input type="date" bind:value={tempEnd} min={tempStart} />
        </div>
      </div>

      <div class="drp-cals">
        <!-- Left calendar -->
        <div class="drp-cal">
          <div class="drp-cal-header">
            <button onclick={prevMonth}><ChevronLeftIcon class="size-3.5" /></button>
            <span>{MONTHS[leftMonth]} {leftYear}</span>
            <button onclick={nextMonth}><ChevronRightIcon class="size-3.5" /></button>
          </div>
          <div class="drp-cal-grid">
            {#each ['Su','Mo','Tu','We','Th','Fr','Sa'] as d}
              <div class="drp-dow">{d}</div>
            {/each}
            {#each leftDays as cell}
              <button
                class="drp-day
                  {cell.out ? 'out' : ''}
                  {isStart(cell.d) ? 'sel-start' : ''}
                  {isEnd(cell.d)   ? 'sel-end'   : ''}
                  {inRange(cell.d) ? 'in-range'  : ''}"
                onclick={() => clickDay(cell.d)}
                onmouseenter={() => hovered = cell.d}
                onmouseleave={() => hovered = ''}
              >{cell.d.slice(8).replace(/^0/, '')}</button>
            {/each}
          </div>
        </div>

        <!-- Right calendar -->
        <div class="drp-cal">
          <div class="drp-cal-header">
            <span></span>
            <span>{MONTHS[rightMonth]} {rightYear}</span>
            <span></span>
          </div>
          <div class="drp-cal-grid">
            {#each ['Su','Mo','Tu','We','Th','Fr','Sa'] as d}
              <div class="drp-dow">{d}</div>
            {/each}
            {#each rightDays as cell}
              <button
                class="drp-day
                  {cell.out ? 'out' : ''}
                  {isStart(cell.d) ? 'sel-start' : ''}
                  {isEnd(cell.d)   ? 'sel-end'   : ''}
                  {inRange(cell.d) ? 'in-range'  : ''}"
                onclick={() => clickDay(cell.d)}
                onmouseenter={() => hovered = cell.d}
                onmouseleave={() => hovered = ''}
              >{cell.d.slice(8).replace(/^0/, '')}</button>
            {/each}
          </div>
        </div>
      </div>

      <div class="drp-actions">
        <button class="drp-cancel" onclick={cancel}>Cancel</button>
        <button class="drp-apply" onclick={apply} disabled={!tempStart || !tempEnd}>Apply</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .drp-trigger {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 0 12px; height: 32px; border-radius: 8px;
    font-size: 12px; font-weight: 500;
    background: var(--surface-1); border: 1px solid var(--surface-border);
    color: var(--text-1); cursor: pointer;
    transition: border-color .15s;
    white-space: nowrap;
  }
  .drp-trigger:hover { border-color: var(--surface-border-hover); }

  .drp-backdrop {
    position: fixed; inset: 0; z-index: 49;
  }

  .drp-popover {
    position: absolute; top: calc(100% + 6px); left: 0;
    z-index: 50;
    display: flex;
    background: var(--surface-1);
    border: 1px solid var(--surface-border);
    border-radius: 12px;
    box-shadow: 0 8px 32px rgba(0,0,0,0.25);
    overflow: hidden;
    min-width: 580px;
  }

  /* Presets */
  .drp-presets {
    display: flex; flex-direction: column;
    padding: 12px 8px;
    border-right: 1px solid var(--surface-border);
    min-width: 148px;
    gap: 2px;
  }
  .drp-preset {
    padding: 7px 12px; border-radius: 6px;
    font-size: 12px; color: var(--text-2);
    background: none; border: none; cursor: pointer;
    text-align: left; transition: background .1s, color .1s;
  }
  .drp-preset:hover, .drp-preset.active { background: var(--surface-2); color: var(--text-1); }

  /* Right panel */
  .drp-right {
    flex: 1; display: flex; flex-direction: column; padding: 16px;
  }

  /* Date inputs */
  .drp-inputs {
    display: flex; align-items: center; gap: 8px; margin-bottom: 16px;
  }
  .drp-input-wrap {
    display: flex; flex-direction: column; gap: 4px; flex: 1;
  }
  .drp-input-wrap label {
    font-size: 10px; text-transform: uppercase; letter-spacing: .6px;
    color: var(--text-3);
  }
  .drp-input-wrap input {
    padding: 6px 10px; border-radius: 6px; font-size: 12px;
    background: var(--surface-2); border: 1px solid var(--surface-border);
    color: var(--text-1); outline: none;
  }
  .drp-input-wrap input:focus { border-color: #70c1a3; }
  .drp-dash { color: var(--text-3); font-size: 14px; margin-top: 16px; }

  /* Calendars */
  .drp-cals { display: flex; gap: 24px; }
  .drp-cal { flex: 1; }
  .drp-cal-header {
    display: flex; align-items: center; justify-content: space-between;
    margin-bottom: 8px;
    font-size: 12px; font-weight: 600; color: var(--text-1);
  }
  .drp-cal-header button {
    background: none; border: none; cursor: pointer;
    color: var(--text-2); padding: 2px; border-radius: 4px;
    display: flex; align-items: center;
  }
  .drp-cal-header button:hover { background: var(--surface-2); }
  .drp-cal-grid {
    display: grid; grid-template-columns: repeat(7, 1fr); gap: 2px;
  }
  .drp-dow {
    font-size: 10px; text-align: center; color: var(--text-3);
    padding: 4px 0; font-weight: 500;
  }
  .drp-day {
    aspect-ratio: 1; display: flex; align-items: center; justify-content: center;
    font-size: 12px; border-radius: 6px; border: none;
    background: none; cursor: pointer; color: var(--text-1);
    transition: background .1s;
    position: relative;
  }
  .drp-day:hover { background: var(--surface-2); }
  .drp-day.out { color: var(--text-3); }
  .drp-day.in-range { background: rgba(112,193,163,0.12); border-radius: 0; }
  .drp-day.sel-start, .drp-day.sel-end {
    background: #70c1a3 !important; color: #0f1f18 !important;
    font-weight: 700; border-radius: 6px;
  }

  /* Actions */
  .drp-actions {
    display: flex; justify-content: flex-end; gap: 8px;
    margin-top: 16px; padding-top: 12px;
    border-top: 1px solid var(--surface-border);
  }
  .drp-cancel {
    padding: 0 14px; height: 30px; border-radius: 6px;
    font-size: 12px; font-weight: 500;
    background: var(--surface-2); border: 1px solid var(--surface-border);
    color: var(--text-2); cursor: pointer;
  }
  .drp-cancel:hover { color: var(--text-1); }
  .drp-apply {
    padding: 0 14px; height: 30px; border-radius: 6px;
    font-size: 12px; font-weight: 600;
    background: #70c1a3; border: none; color: #0f1f18; cursor: pointer;
  }
  .drp-apply:hover { background: #8dd0b5; }
  .drp-apply:disabled { opacity: .4; cursor: not-allowed; }
</style>
