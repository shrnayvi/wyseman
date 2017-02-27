-- Bootstrap the schema with table containing create/drop data about all other objects
-- TODO:
-- X- How to prune the dependencies for objects that can be replaced (functions/views)
-- X- Make routine:
-- X-  optional drop and/or create
-- X-  drop in reverse depth order
-- X-  create in depth order
-- X-  optional, but default, preserve data in tables
-- X- Is there a way to dump tables (like pg_dump) direct from database
-- X- Implement release table
-- X- Move dependencies to a view/virtual table
-- X- Keep grants in object table with create sql
-- X- Finish wm.grant for new way
-- X- Items must track which module,release they are a part of
-- X- Find orphaned objects and delete them
-- X- When deleting an item from objects, delete the actual object too
-- - 
-- - Test: Can't change items part of a prior release
-- - If table columns have changed, apply alter script before drop/create of table
-- - Function to output sql for a module, release
-- - 

create schema wm;		-- Holds all the wyseman objects

-- Track official module releases
-- Whatever is max(release) is the current, working copy
-- max(release) - 1 is the last-committed release, not to be changed again
-- ----------------------------------------------------------------------------
create table wm.releases (
    release	int		primary key default 1 check(release > 0)
  , crt_date	timestamp(0)	default current_timestamp	-- When development started on this release level
  , sver_1	int		-- Dummy column indicates the version of this bootstrap schema
);
insert into wm.releases (release) values (1);

-- Latest (working) release number
-- ----------------------------------------------------------------------------
create or replace function wm.release() returns int stable language sql as $$
  select coalesce(max(release),1) from wm.releases
$$;

-- Contains an entry for each database object we are creating
-- ----------------------------------------------------------------------------
create table wm.objects (
    obj_typ	varchar		not null		-- table, view, trigger, etc.
  , obj_nam	varchar		not null		-- schema.name
  , obj_ver	int		not null default 0	-- incremented when the object changes from the last committed release
  , checked	boolean		default false		-- checked for merge, dependencies
  , clean	boolean		default false		-- instantiated in current database
  , module	varchar		not null		-- name of the schema group this object belongs to
  , mod_ver	int					-- version of the schema group this object belongs to
  , source	varchar		not null		-- name of the source file this object defined in
  , deps	varchar[]	not null		-- List of dependencies, as user entered them
  , ndeps	varchar[]				-- List of normalized dependencies
  , grants	varchar[]	not null default '{}'	-- List of grants
  , col_data	varchar[]	not null default '{}'	-- Extra data about columns, for views
  , crt_sql	varchar		not null		-- SQL to create the object
  , drp_sql	varchar		not null		-- SQL to drop the object
  , min_rel	int		default wm.release()	-- smallest release this object belongs to
  , max_rel	int		default wm.release()	-- largest release this object belongs to
  , crt_date	timestamp(0)	default current_timestamp	-- When record created
  , mod_date	timestamp(0)	default current_timestamp	-- When record last modified
  , primary key (obj_typ, obj_nam, obj_ver)
);

-- Before deleting an object
-- ----------------------------------------------------------------------------
create or replace function wm.objects_tf_bd() returns trigger language plpgsql security definer as $$
  begin
    if old.min_rel < wm.release() then		-- If object belongs to earlier releases
      raise 'Object %:% part of an earlier committed release', old.obj_typ, old.obj_nam;
    elsif old.max_rel > old.min_rel then
      update wm.objects set max_rel = max_rel - 1 where obj_typ = old.obj_typ and obj_nam = old.obj_nam and obj_ver = wm.release();
      return null;
    elsif old.clean then
      perform wm.make(array[old.obj_typ || ':' || old.obj_nam], true, false);
    end if;
    return old;
  end;
$$;
create trigger tr_bd before delete on wm.objects for each row execute procedure wm.objects_tf_bd();

-- Store a grant in the object table
-- ----------------------------------------------------------------------------
create or replace function wm.grant(
    otyp	varchar		-- Object type we're granting permissions to
  , onam	varchar		-- Object name we're granting permissions to
  , priv	varchar		-- A privilege name, defined for the application
  , level	int		-- Application defined level 1,2,3 etc
  , allow	varchar		-- select, insert, update, delete, etc
) returns boolean language plpgsql as $$
  declare
    pstr	varchar default array_to_string(array[otyp||':'||onam,priv,level::varchar,allow], ',');
    grlist	varchar[];
    cln		boolean;	-- from object record
  begin
    select grants, clean into grlist, cln from wm.objects where obj_typ = otyp and obj_nam = onam and obj_ver = 0;
    if not FOUND then
      raise 'Can not find defined object:%:% to associate permissions with', otyp, onam;
    end if;
    if pstr = any(grlist) then
      if not cln then raise notice 'Grant: % multiply defined on object:%:%', pstr, otyp, onam; end if;
      return false;
    else
      update wm.objects set clean = false, grants = grlist || pstr where obj_typ = otyp and obj_nam = onam and obj_ver = 0;
    end if;
    return true;
  end;
$$;

-- Standard view of dependencies with level and path information
-- ----------------------------------------------------------------------------
create or replace view wm.depends_v as
  with recursive search_deps(object, obj_typ, obj_nam, depend, release, depth, path, cycle) as (
      select (o.obj_typ || ':' || o.obj_nam)::varchar as object, o.obj_typ, o.obj_nam, null::varchar, r.release,0, '{}'::varchar[], false
 	from	wm.objects	o
 	join	wm.releases	r on r.release between o.min_rel and o.max_rel
  	where o.ndeps = '{}'            		-- level 1 dependencies
    union
      select (o.obj_typ || ':' || o.obj_nam)::varchar as object, o.obj_typ, o.obj_nam, d, r.release,depth + 1, path || d, d = any(path)
 	from	wm.objects	o
 	join	wm.releases	r	on r.release between o.min_rel and o.max_rel
 	join	unnest(o.ndeps)	d	on true
        join    search_deps     dr	on dr.object = d and dr.release = r.release	-- iterate through dependencies
        where			not cycle
  ) select *, path || object as fpath from search_deps;

-- View of objects and each release they belong to
-- ----------------------------------------------------------------------------
create or replace view wm.objects_v as
  select o.obj_typ || ':' || o.obj_nam as object, o.*, r.release
  from		wm.objects	o
  join		wm.releases	r	on r.release between o.min_rel and o.max_rel;
  
-- Check any draft entries, to be merged or promoted
-- ----------------------------------------------------------------------------
create or replace function wm.check_drafts(orph boolean default false) returns boolean language plpgsql as $$
  declare
    drec	record;		-- draft object record
    prec	record;		-- previous latest record
    changes	boolean default false;
  begin
    if orph then		-- Find any orphaned objects
      for drec in		
        select o.*
          from	wm.objects	o
          join	(select distinct module, source from wm.objects where obj_ver = 0) as od on od.module = o.module and od.source = o.source
          where 	wm.release() between o.min_rel and o.max_rel
          and	not exists (select obj_nam from wm.objects where obj_typ = o.obj_typ and obj_nam = o.obj_nam and obj_ver = 0)
          loop
raise notice 'Orphan: %:%', drec.obj_typ, drec.obj_nam;
            delete from wm.objects where obj_typ = drec.obj_typ and obj_nam = drec.obj_nam and obj_ver = drec.obj_ver;
      end loop;
    end if;

    for drec in select * from wm.objects where obj_ver = 0 loop		-- For each newly parsed record
      if not exists (select * from wm.objects where obj_typ = drec.obj_typ and obj_nam = drec.obj_nam and obj_ver > 0) then
raise notice 'Adding: %:%', drec.obj_typ, drec.obj_nam;
        update wm.objects set obj_ver = 1, mod_date = current_timestamp where obj_typ = drec.obj_typ and obj_nam = drec.obj_nam and obj_ver = 0;
        continue;
      end if;

      select * into prec from wm.objects where obj_typ = drec.obj_typ and obj_nam = drec.obj_nam order by obj_ver desc limit 1;	-- Get the latest non-draft record
      if (drec.crt_sql  is distinct from prec.crt_sql)	or	-- Has anything important changed?
         (drec.drp_sql  is distinct from prec.drp_sql)	or
         (drec.deps     is distinct from prec.deps)	or
         (drec.col_data is distinct from prec.col_data)	or
         (drec.grants   is distinct from prec.grants)	then
       
        if prec.min_rel >= wm.release() then		-- if prior record starts with the current working release, then update it with our new changes
raise notice 'Modify: %:%', drec.obj_typ, drec.obj_nam;
          update wm.objects set checked = false, clean = false, module = drec.module, mod_ver = drec.mod_ver, source = drec.source, deps = drec.deps, grants = drec.grants, col_data = drec.col_data, crt_sql = drec.crt_sql, drp_sql = drec.drp_sql, mod_date = current_timestamp where obj_typ = prec.obj_typ and obj_nam = prec.obj_nam and obj_ver = prec.obj_ver;
          delete from wm.objects where obj_typ = drec.obj_typ and obj_nam = drec.obj_nam and obj_ver = 0;
        else						-- else, prior record belongs to earlier, committed releases, so create a new, modified record
raise notice 'Increm: %:%', drec.obj_typ, drec.obj_nam;
          update wm.objects set max_rel = wm.release()-1, clean = true where obj_typ = prec.obj_typ and obj_nam = prec.obj_nam and obj_ver = prec.obj_ver;
          update wm.objects set obj_ver = prec.obj_ver + 1, checked = false, clean = false, mod_date = current_timestamp where obj_typ = drec.obj_typ and obj_nam = drec.obj_nam and obj_ver = drec.obj_ver;
        end if;
      else						-- No changes from prior record, so delete the draft record
raise notice 'Ignore: %:%', drec.obj_typ, drec.obj_nam;
        delete from wm.objects where obj_typ = drec.obj_typ and obj_nam = drec.obj_nam and obj_ver = 0;
      end if;
    end loop;
    return true;
  end;
$$;
    
-- Normalize dependencies on yet unchecked objects
-- ----------------------------------------------------------------------------
create or replace function wm.check_deps() returns boolean language plpgsql as $$
  declare
    orec	record;		-- Outer loop record
    trec	record;		-- Dependency record
    d		varchar;	-- Iterator
    darr	varchar[];	-- Accumulates cleaned up array
  begin
    for orec in select * from wm.objects_v where not checked loop
-- raise notice 'Checking object:% deps:%', orec.object, orec.deps;
      darr = '{}';
      foreach d in array orec.deps loop
-- raise notice '            dep:%', d;
          select * into trec from wm.objects_v where object = d and release = orec.release;	-- Is this a full object name?
          if not FOUND then
            begin
              select * into strict trec from wm.objects_v where obj_nam = d and release = orec.release;	-- Is it just the name, with no type
              EXCEPTION
                when NO_DATA_FOUND then
                  raise exception 'Dependency:%, by object:%, not found', d, orec.object;
                when TOO_MANY_ROWS then
                  raise exception 'Dependency:%, by object:%, not unique', d, orec.object;
            end;
            d = trec.object;				-- Use fully qualified object name
          end if;
-- raise notice '         insert:%:%', orec.object, d;
          darr = darr || d;
      end loop;
      update wm.objects set ndeps = darr, checked = true where obj_typ = orec.obj_typ and obj_nam = orec.obj_nam and obj_ver = orec.obj_ver;		-- Write out cleaned up array
    end loop;
    return true;
  end;
$$;

-- Check data integrity; Execute after each parsing run
-- ----------------------------------------------------------------------------
create or replace function wm.check_all(prune boolean default true, make boolean default true) returns boolean language plpgsql as $$
  begin
    if wm.check_drafts(prune) then
      perform wm.check_deps();
    end if;
    delete from wm.objects where obj_ver = 0;
    if make and wm.make(null,false,true) > 0 then
      perform wm.init_dictionary();
    end if;
    return true;
  end;
$$;

-- View of objects including their maximum depth
-- ----------------------------------------------------------------------------
create or replace view wm.objects_v_depth as
  select o.*, od.depth
  from		wm.objects_v	o
  join		(select obj_typ, obj_nam, release, max(depth) as depth from wm.depends_v group by 1,2,3) od on od.obj_typ = o.obj_typ and od.obj_nam = o.obj_nam and od.release = o.release
  order by	depth;

-- Attempt to replace a view or function
-- ----------------------------------------------------------------------------
create or replace function wm.replace(obj varchar) 
  returns boolean language plpgsql as $$
  declare
    trec	record;
  begin

    select * into strict trec from wm.objects_v where object = obj and release = wm.release();
    execute regexp_replace(trec.crt_sql,'create ','create or replace ','ig');
raise notice 'Replace:% :%:', trec.depth, trec.object;
    update wm.objects set clean = true where obj_typ = trec.obj_typ and obj_nam = trec.obj_nam and obj_ver = trec.obj_ver;
    return true;
  end;

$$;

-- Drop/create a group of database objects
-- ----------------------------------------------------------------------------
create or replace function wm.make(
    objs varchar[]		-- array of objects to act on
  , drp boolean default true	-- drop objects in the specified branch
  , crt boolean default true	-- create objects in the specified branch
  , wrk text default '/var/tmp/wyseman'	-- server folder to store temp backup files in
) returns int language plpgsql as $$
  declare
    s		varchar;		-- temporary string
    trec	record;			-- temp record
    irec	record;			-- info record
    objlist	varchar[] default '{}';	-- expanded list of objects we will work on
    collist	varchar;		-- list of columns to save/restore in table
    cnt		int;			-- how many records saved/restored
    garr	varchar[];		-- grant array
    glev	varchar;		-- grant group_level
    otype	varchar;		-- object type, coerced to table for views
    counter	int default 0;		-- how many objects we build
  begin
    if objs is null then		-- Defaults to drop/create of all unclean objects
      objs = '{}';
      for s in select object from wm.objects_v where not clean loop
        objs = objs || s;
      end loop;
    end if;
  
    foreach s in array objs loop	-- for each specified object, expand to dependent objects
      objlist = objlist || array(select distinct object from wm.depends_v where s = any(fpath) and release = wm.release());
    end loop;
-- raise notice 'objlist:%', objlist;
    create temporary table _table_info (obj_nam varchar primary key, columns varchar, fname varchar, rows int);

    if drp then			-- Drop specified objects
      for trec in select * from wm.objects_v_depth where object = any(objlist) and release = wm.release() order by depth desc loop
raise notice 'Drop:% :%:', trec.depth, trec.object;

        if trec.obj_typ = 'table' then
          begin
            execute 'select count(*) from ' || trec.obj_nam || ';' into strict cnt;
            exception when undefined_table then
              raise notice 'Skipping non-existant: %:%', trec.obj_typ, trec.obj_nam;
              continue;
          end;
        end if;
        if trec.obj_typ = 'table' and cnt > 0 then		-- Attempt to preserve existing table data
          collist = array_to_string(array(select column_nam::text from information_schema.columns where table_schema || '.' || table_nam = trec.obj_nam order by ordinal_position),',');
-- raise notice 'collist:%', collist;
          s = wrk || '/' || trec.obj_nam || '.dump';
          execute 'copy ' || trec.obj_nam || '(' || collist || ') to ''' || s || '''';
          get diagnostics cnt = ROW_COUNT;
-- raise notice 'Count:%', cnt;
          insert into _table_info (obj_nam,columns,fname,rows) values (trec.obj_nam, collist, s, cnt);
        end if;

        execute trec.drp_sql;
      end loop;
    end if;

    if crt then			-- Create specified objects
      for trec in select * from wm.objects_v_depth where object = any(objlist) and release = wm.release() order by depth loop
raise notice 'Create:% :%:', trec.depth, trec.object;
        execute trec.crt_sql;
        
        if trec.obj_typ = 'table' then		-- Attempt to restore data into the table
          select * into irec from _table_info i where i.obj_nam = trec.obj_nam;
          if FOUND then
            execute 'copy ' || trec.obj_nam || '(' || irec.columns || ') from ''' || irec.fname || '''';
            execute 'select count(*) from ' || trec.obj_nam || ';' into strict cnt;
            if cnt != irec.rows then
              raise exception 'Restored % records to table % when % had been saved', cnt, trec.obj_nam, irec.rows;
            end if;
          end if;
        end if;
        
        foreach s in array trec.grants loop	-- for each specified object, expand to dependent objects
-- raise notice 'Grant:% :%', trec.object, s;
          garr = string_to_array(s,',');
          glev = garr[2] || '_' || garr[3];
          if garr[2] = 'public' then
            glev = garr[2];
          elsif not exists (select rolname from pg_roles where rolname = glev) then
            execute 'create role ' || glev || ';';
          end if;
          otype = trec.obj_typ; if otype = 'view' then otype = 'table'; end if;
          execute 'grant ' || garr[4] || ' on ' || otype || ' ' || trec.obj_nam || ' to ' || glev || ';'; 
        end loop;
        update wm.objects set clean = true where obj_typ = trec.obj_typ and obj_nam = trec.obj_nam and obj_ver = trec.obj_ver;
        counter = counter + 1;
      end loop;
    end if;

    drop table _table_info;
    return counter;
  end;
$$;