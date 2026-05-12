<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Coming Soon — tradingchart.org</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; }
    html, body {
      margin: 0;
      padding: 0;
      width: 100vw;
      height: 100vh;
      min-height: 100vh;
      min-width: 100vw;
      overflow: hidden;
    }
    body {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 2rem;
      font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
      color: #fafafa;
      background-color: #0f1419;
      background-image: url("https://images.pexels.com/photos/35755755/pexels-photo-35755755.jpeg");
      background-size: cover;
      background-position: center;
      background-repeat: no-repeat;
      position: relative;
    }
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      background: rgba(15, 20, 25, 0.55);
      z-index: 0;
    }
    body > * {
      position: relative;
      z-index: 1;
    }
    .wrap {
      text-align: center;
      max-width: 90vw;
    }
    h1 {
      margin: 0 0 0.5rem;
      font-size: clamp(1.5rem, 4vw, 2.25rem);
      font-weight: 600;
      letter-spacing: -0.02em;
      text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
    }
    .domain {
      margin: 0;
      font-size: clamp(0.95rem, 2.5vw, 1.125rem);
      color: #d4d4d8;
      text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5);
    }
    .domain a {
      color: #93c5fd;
      text-decoration: none;
    }
    .domain a:hover { text-decoration: underline; }

    /* HTML: <div class="loader"></div> */
    .loader {
      width: 50px;
      aspect-ratio: 1;
      border-radius: 50%;
      border: 8px solid;
      border-color: #000 #0000;
      animation: l1 1s infinite;
    }
    @keyframes l1 { to { transform: rotate(.5turn); } }
  </style>
</head>
<body>
  <div class="loader" aria-hidden="true"></div>
  <div class="wrap">
    <h1>Coming soon</h1>
    <p class="domain"><a href="https://tradingchart.org" rel="noopener">tradingchart.org</a></p>
  </div>
</body>
</html>
