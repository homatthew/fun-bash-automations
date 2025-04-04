set number
syntax on

set autoindent
set smartindent
set expandtab
set tabstop=2
set shiftwidth=2
set softtabstop=2
filetype indent on

set showmatch
set wildmenu

set ruler                 " Show the cursor position all the time
set hlsearch              " Highlight all search results
set incsearch             " Show search matches as you type
set ignorecase            " Ignore case in search patterns
set smartcase             " Override ignorecase if search pattern contains uppercase

set cursorline
" set relativenumber        " Show relative line numbers

set mouse=a

" use 'brew install vim' if shared clipboard doesn't work
set clipboard=unnamed
set backspace=indent,eol,start

" Highlight trailing whitespace
highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/

" Automatically remove trailing whitespace on save
autocmd BufWritePre * :%s/\s\+$//e

