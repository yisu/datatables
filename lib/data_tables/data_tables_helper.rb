module DataTablesHelper
  def datatables(source, opts = {})

    options = opts[:jquery] ? opts[:jquery].dup : {}
    options[:bJQueryUI] = true unless options.has_key?(:bJQueryUI)
    options[:bProcessing] = true unless options.has_key?(:bProcessing)
    options[:bServerSide] = true unless options.has_key?(:bServerSide)
    options[:bAutoWidth] = false unless options.has_key?(:bAutoWidth)
    options[:bStateSave] = true unless options.has_key?(:bStateSave)
    options[:sScrollY] = "200px"
    options[:sScrollX] = '100%'
    options[:bScrollCollapse] = true
    options[:bDeferRender] = true
    options[:bScrollInfinite] = true
    options[:iDisplayLength] = 100
    options[:bFilter] = true

    options[:bFilter] = opts[:search] unless opts[:search].nil?

    options[:fnInitComplete] ||= "function() {
      if (eval('typeof ' + initDatatablesTable) == 'function') {
        initDatatablesTable('#{source}');
      }
    }"

    options[:fnServerData] ||= "function ( sSource, aoData, fnCallback ) {
      var init_sSearch = $('#init_sSearch');
      var start_time = $('#start_time');
      var end_time = $('#end_time');
      if(init_sSearch != undefined && init_sSearch.val() != '' && init_sSearch.size() != 0) {
        $('.dataTables_filter input').val(init_sSearch.val());
        aoData.push( { name:'sSearch', value: init_sSearch.val() });
        $('#init_sSearch').remove();
      }
      if(start_time.val() != undefined && start_time.val() != '' && end_time.val() != undefined && end_time.val() != '') {
        aoData.push( { name:'sStarttime', value:start_time.val() });
        aoData.push( { name:'sEndtime', value:end_time.val() });
      }
      $.ajax( {
                'dataType': 'json',
                'url': sSource,
                'data': aoData,
                'success': fnCallback
                });
      }"

    options[:fnDrawCallback] = "function() {
      change_scrollY();
    }"

    sdom = options[:bFilter] ? '<"#datatables_search_hint">lfrtip' : 'lrtip'
    sdom = "C<\"clear\">" + sdom
    sdom = 'T' + sdom if options[:oTableTools]
    options[:sDom] ||= sdom

    # Rails.logger.info("*****#{options.inspect}")

    # options[:sDom].delete(:f)

    datatable = controller.datatable_source(source)
    url_query_params = opts[:urlQueryParams] || {}
    options[:sAjaxSource] = opts[:sAjaxSource] ||
        method("#{datatable[:action]}_url".to_sym).call(url_query_params)
    columns = datatable[:attrs].keys.collect { |a| "<th>#{a}</th>" }.join

    index = 0
    first_searchable_column_index = nil
    targets = datatable[:attrs].inject([]) do |memo, (column, searchable)|
      first_searchable_column_index ||= index if searchable
      memo << index unless searchable
      index += 1
      memo
    end
    options[:aaSorting] ||= [[first_searchable_column_index, 'asc']]
    options[:aoColumnDefs] ||= []
    options[:aoColumnDefs].unshift({
                                     :aTargets => targets,
                                     :bSearchable => false,
                                     :bSortable => false
                                   })

    if options[:html]
      html_opts = options[:html].collect { |k,v| "#{k}=\"#{v}\"" }.join(' ')
    end
    pad_ao_columns(options, datatable[:attrs].keys.size)

    table_header = "<tr>#{columns}</tr>"
    html = "
<script>
$(document).ready(function() {
  var oTable = $('##{datatable[:action]}').dataTable({
    #{datatables_option_string(options)}
  });
  showFilteredData();
  oTable.fnDraw();
  $('tfoot input').keyup( function () {
    /* Filter on the column (the index) of this element */
    oTable.fnFilter( this.value, $('tfoot input').index(this) );
   });
  $('#custom_interval_select_log').click( function () {
    custom_interval_select_handler_log($('#custom_start').val(),$('#custom_end').val());
    oTable.fnDraw();
  });
  $('.interval').change( function () {
    interval_click_handler_log();
    oTable.fnDraw();
  });
  $('.dataTables_filter').after($('#tab_options_popup'));
  $('.dataTables_filter').after($('#interval_choice'));
});

  function change_scrollY() {
    $('.dataTables_scrollHeadInner').css('padding-right','17px');
    $('.dataTables_scrollHeadInner').width('100%');
    $('.dataTable').width('100%');
    $('##{datatable[:action]}').dataTable().fnAdjustColumnSizing(false);
    $('.dataTables_scrollHead').width('100%');
    $('.dataTables_scrollBody').width('100%');
    h = $('##{source}').height();
    if( h > $(window).height() *55/100 )
    {
      $('.dataTables_scrollBody').css('height', ($(window).height() *55/100));
    }
    else
    {
      $('.dataTables_scrollBody').css('height', h+20);
    }
    $('.dataTables_scrollBody').trigger('scroll');
    if($('.dataTable').width() < $('.dataTables_scrollHead').width())
    {
      $('.dataTable').width('100%');
      $('.dataTables_scrollHeadInner').width($('##{source}').width());
    }
  }

  $(window).resize(change_scrollY);

</script>
<table id=\"#{datatable[:action]}\" #{html_opts}>
<thead>
#{table_header}
</thead>
<tbody>
</tbody>
</table>
"
    return raw(html)
  end
end

def datatables_option_string(options, indent = 4)
  arr = []
  options.each do |key, value|
    if value.is_a?(String) && value[0..7] != "function"
      arr << "#{' ' * indent}#{key}: '#{value}'"
    elsif value.is_a?(Array)
      indent += 2
      item_arr = []
      value.each do |item|
        if item.is_a?(Hash)
          str = "#{' ' * indent}{\n"
          str += "#{datatables_option_string(item, indent + 2)}\n"
          str += "#{' ' * indent}}"
          item_arr << str
        elsif item.is_a?(String) && item[0..7] != "function"
          item_arr << "#{' ' * indent}'#{item}'"
        else
          item_arr << "#{' ' * indent}#{item}"
        end
      end
      indent -= 2
      arr << "#{' ' * indent}#{key}: [\n#{item_arr.join(",\n")}\n#{' ' * indent}]"
    elsif value.is_a?(Hash)
      str = "#{' ' * indent}#{key}: {\n"
      str += "#{datatables_option_string(value, indent + 2)}\n"
      str += "#{' ' * indent}}"
      arr << str
    else
      arr << "#{' ' * indent}#{key}: #{value}"
    end
  end

  arr.join(",\n")
end

def pad_ao_columns(options, count)
  return unless options[:aoColumns]

  (count - options[:aoColumns].size).times do
    options[:aoColumns] << 'null'
  end
end
