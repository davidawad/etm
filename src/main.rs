//! `etm` CLI: argv → request → envelope on stdout, exit code per the
//! envelope. See the crate docs and `etm help`.

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(etm::app::run(&argv, etm::app::Hooks::default()));
}
