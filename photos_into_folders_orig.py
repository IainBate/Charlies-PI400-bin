from pathlib import Path
from datetime import datetime

def organize_files_by_date(src_dir: Path, target_dir: Path, dry_run=False):
    if not target_dir.exists() and not dry_run: target_dir.mkdir()
    assert target_dir.is_dir() or dry_run
    for path in src_dir.iterdir():
        if path.is_dir(): organize_files_by_date(path, target_dir)
        else:
            stat = path.stat()
            if hasattr(stat, 'st_birthtime'): ftime = stat.st_birthtime
            else: ftime = stat.st_mtime
            fdate = datetime.fromtimestamp(ftime)
            f_folder = target_dir / fdate.strftime("%Y - %B")
            if not f_folder.exists() and not dry_run: f_folder.mkdir()
            assert f_folder.is_dir() or dry_run
            f_target = f_folder / path.name
            assert not f_target.exists()
            print(f"{path}->{f_target}")
            if not dry_run:
                path.rename(f_target)


organize_files_by_date(Path('src_folder'), Path('target_folder'), dry_run=False)
