import {
  ArcElement,
  BarController,
  BarElement,
  CategoryScale,
  Chart,
  DoughnutController,
  Legend,
  LinearScale,
  LineController,
  LineElement,
  PieController,
  PointElement,
  Tooltip,
} from 'chart.js';

// Only what the pop-up and modal charts use (ADR 0003, ADR 0012): bar and
// line charts on a category x axis and a linear y axis, pie and doughnut
// charts, tooltips, and a legend for several series or slices. Loaded on
// first use (see FeatureChart), so Chart.js is not in the initial bundle.
Chart.register(
  ArcElement,
  BarController,
  BarElement,
  DoughnutController,
  LineController,
  LineElement,
  PieController,
  PointElement,
  CategoryScale,
  LinearScale,
  Legend,
  Tooltip,
);

export { Chart };
