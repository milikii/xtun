(function () {
  var canvas = document.getElementById("signalCanvas");

  if (!canvas || !canvas.getContext) {
    return;
  }

  var ctx = canvas.getContext("2d");
  var nodes = [];

  function seedNodes(width, height) {
    nodes = [];
    var count = Math.max(22, Math.min(42, Math.floor(width / 18)));
    for (var i = 0; i < count; i += 1) {
      nodes.push({
        x: Math.random() * width,
        y: Math.random() * height,
        vx: (Math.random() - 0.5) * 0.45,
        vy: (Math.random() - 0.5) * 0.45,
        r: 2 + Math.random() * 3,
        hue: i % 3
      });
    }
  }

  function resize() {
    var rect = canvas.getBoundingClientRect();
    var scale = window.devicePixelRatio || 1;
    var width = Math.max(1, Math.floor(rect.width));
    var height = Math.max(1, Math.floor(rect.height));
    canvas.width = Math.floor(width * scale);
    canvas.height = Math.floor(height * scale);
    ctx.setTransform(scale, 0, 0, scale, 0, 0);
    seedNodes(width, height);
  }

  function colorFor(index) {
    if (index === 0) {
      return "#2563eb";
    }
    if (index === 1) {
      return "#07845f";
    }
    return "#6d5bd0";
  }

  function draw() {
    var width = canvas.clientWidth;
    var height = canvas.clientHeight;
    ctx.clearRect(0, 0, width, height);

    ctx.strokeStyle = "rgba(102, 112, 133, 0.14)";
    ctx.lineWidth = 1;
    for (var x = 32; x < width; x += 56) {
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x + 30, height);
      ctx.stroke();
    }
    for (var y = 34; y < height; y += 54) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(width, y + 18);
      ctx.stroke();
    }

    for (var i = 0; i < nodes.length; i += 1) {
      var a = nodes[i];
      a.x += a.vx;
      a.y += a.vy;

      if (a.x < 12 || a.x > width - 12) {
        a.vx *= -1;
      }
      if (a.y < 12 || a.y > height - 12) {
        a.vy *= -1;
      }

      for (var j = i + 1; j < nodes.length; j += 1) {
        var b = nodes[j];
        var dx = a.x - b.x;
        var dy = a.y - b.y;
        var distance = Math.sqrt(dx * dx + dy * dy);
        if (distance < 128) {
          ctx.globalAlpha = 1 - distance / 128;
          ctx.strokeStyle = "rgba(37, 99, 235, 0.2)";
          ctx.beginPath();
          ctx.moveTo(a.x, a.y);
          ctx.lineTo(b.x, b.y);
          ctx.stroke();
        }
      }
    }

    ctx.globalAlpha = 1;
    nodes.forEach(function (node) {
      ctx.fillStyle = colorFor(node.hue);
      ctx.beginPath();
      ctx.arc(node.x, node.y, node.r, 0, Math.PI * 2);
      ctx.fill();
    });

    window.requestAnimationFrame(draw);
  }

  window.addEventListener("resize", resize);
  resize();
  window.requestAnimationFrame(draw);
})();
