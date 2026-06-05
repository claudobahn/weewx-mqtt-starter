<!-- AOS composite radar loop (UW-Madison; covers the Milwaukee region).
     Mirrors the live MCSC site's radar placement (in-column, below the gauges,
     above station info). All 20 frames are mounted as <img> elements stacked
     in the same slot; cycling swaps `display:block` between them so no
     network request fires per cycle iteration. The set is refetched every
     REFRESH_MS to pick up newly-issued radar scans (AOS overwrites the same
     filenames). Without this layout the naive `img.src=...` loop revalidates
     each frame against the server roughly every 12 min (AOS sends no
     Cache-Control / Expires headers, so browsers use heuristic freshness
     ~= 10% of file age) -- at 4 fps that's ~80 conditional requests per
     second per open dashboard, mostly 304s. -->
<div class="row mt-3">
    <div class="col-12 text-center">
        <a href="http://tempest.aos.wisc.edu/radar/wi3compjs.html"
           title="UW-Madison AOS composite radar">
            <div id="radar-loop-stack" style="position:relative; line-height:0;"></div>
        </a>
    </div>
</div>
<script>
(function() {
  var stack = document.getElementById('radar-loop-stack');
  if (!stack) return;

  var FRAMES = 20;
  var BASE = 'http://tempest.aos.wisc.edu/radar/wi3comp';
  var CYCLE_MS = 250;                    // animation frame interval (unchanged feel)
  var REFRESH_MS = 6 * 60 * 1000;        // refetch all frames every 6 min
                                         // (matches AOS's scan cadence observed
                                         // in the gif Last-Modified timestamps)
  var imgs = [];
  var idx = 0;

  function frameUrl(i, ts) {
    return BASE + (i < 10 ? '0' + i : i) + '.gif?_=' + ts;
  }

  function rebuild() {
    // Tear down the old stack and request a fresh set. Cache-bust so
    // the browser doesn't serve a stale frame from the heuristic cache.
    imgs.forEach(function(im) { stack.removeChild(im); });
    imgs = [];
    idx = 0;
    var ts = Date.now();
    for (var i = 1; i <= FRAMES; i++) {
      var im = document.createElement('img');
      im.alt = 'UW-Madison AOS composite radar (Milwaukee region)';
      im.style.maxWidth = '100%';
      im.style.height = 'auto';
      // Start with only the first frame visible; rest are display:none
      // until cycle() rotates onto them. Decoded pixels stay resident.
      im.style.display = (i === 1) ? 'block' : 'none';
      im.src = frameUrl(i, ts);
      stack.appendChild(im);
      imgs.push(im);
    }
  }

  function cycle() {
    if (imgs.length === 0 || document.hidden) return;
    imgs[idx].style.display = 'none';
    idx = (idx + 1) % imgs.length;
    imgs[idx].style.display = 'block';
  }

  rebuild();
  setInterval(rebuild, REFRESH_MS);
  setInterval(cycle, CYCLE_MS);
})();
</script>
