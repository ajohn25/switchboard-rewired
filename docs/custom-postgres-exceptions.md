# Custom Postgres Exceptions

> If your exception matches one of the SQLSTATEs in [Appendix A](https://www.postgresql.org/docs/current/errcodes-appendix.html) of the PostgreSQL documentation, simply use that SQLSTATE.
>
> If you need to use your own SQLSTATE, let it begin with any of 5 to 9 or I to Z (but avoid the SQLSTATEs used by PostgreSQL).
>
> If you need to define a custom warning, use an SQLSTATE that starts with 01 and whose third character is any of 5 to 9 or I to Z.
>
> -- https://dba.stackexchange.com/a/258336

## Warnings

<table>
  <thead>
    <tr>
      <th>ErrCode</th>
      <th>Condition</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td colspan="2">n/a</td>
    </tr>
  </tbody>
</table>

## Errors

<table>
  <thead>
    <tr>
      <th>ErrCode</th>
      <th>Condition</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td colspan="2"><b>Class SI — Switchboard Inbound</b></td>
    </tr>
    <tr>
      <td><code>SI000</code></td>
      <td><code>no_active_sending_tn</code></td>
    </tr>
  </tbody>
</table>
