-- What the branch's printer can do, as the print station last reported it (null = not known): the bot
-- then offers only colour / two-sided printing where the printer has them.
alter table print_stations add column color boolean;
alter table print_stations add column duplex boolean;
