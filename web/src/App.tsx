import { Navigate, Route, Routes, useLocation } from "react-router-dom";
import { useAuth } from "./lib/auth";
import { Shell, Spinner } from "./components/ui";
import Login from "./pages/Login";
import Board from "./pages/Board";
import Match from "./pages/Match";
import FillCard from "./pages/FillCard";
import LiveCard from "./pages/LiveCard";
import Crews from "./pages/Crews";
import CrewRoom from "./pages/CrewRoom";
import Album from "./pages/Album";
import Table from "./pages/Table";
import Profile from "./pages/Profile";
import Settings from "./pages/Settings";
import About from "./pages/About";
import Privacy from "./pages/Privacy";
import { ConsentBar, Footer } from "./features/ads/ConsentBar";

export default function App() {
  const { session, loading } = useAuth();
  const loc = useLocation();
  if (loading) return <Spinner />;
  // §ads /about and /privacy are reachable signed out: a cookie banner that links to a page
  // behind a login is not a cookie banner.
  if (!session) {
    return (
      <>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route path="/about" element={<div className="wrap"><About /><Footer /></div>} />
          <Route path="/privacy" element={<div className="wrap"><Privacy /><Footer /></div>} />
          <Route path="*" element={<Navigate to="/login" replace state={{ from: loc.pathname }} />} />
        </Routes>
        <ConsentBar />
      </>
    );
  }
  return (
    <Shell>
      {/* keyed by path: each page animates in; the board's ?sport= filter does not re-trigger it */}
      <div className="page" key={loc.pathname}>
      <Routes>
        <Route path="/" element={<Board />} />
        <Route path="/match/:id" element={<Match />} />
        <Route path="/card/:id" element={<FillCard />} />
        <Route path="/card/:id/live" element={<LiveCard />} />
        <Route path="/crews" element={<Crews />} />
        <Route path="/crews/:id" element={<CrewRoom />} />
        <Route path="/album" element={<Album />} />
        <Route path="/table" element={<Table />} />
        <Route path="/you" element={<Profile />} />
        <Route path="/settings" element={<Settings />} />
        <Route path="/about" element={<About />} />
        <Route path="/privacy" element={<Privacy />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      </div>
      <Footer />
      <ConsentBar />
    </Shell>
  );
}
